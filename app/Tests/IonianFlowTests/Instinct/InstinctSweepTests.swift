import Foundation
import Testing
@testable import IonianFlow

@Suite struct InstinctSweepTests {
    static let noCheckpoint: () async -> Void = {}
    static let transcriptName = "2026-11-05 10-02.md"

    struct Fixture {
        let brain: FixtureBrain
        let instinct: URL
        let model = FakeInstinctModel()
        let now = TranscriptSourceTests.local("2026-11-05 12:00")

        init() throws {
            brain = try FixtureBrain()
            try brain.write("projects/alpha.md", FixtureBrain.alpha)
            instinct = FileManager.default.temporaryDirectory.appendingPathComponent("instinct-\(UUID().uuidString)")
        }
        var transcripts: URL { brain.root.appendingPathComponent("transcripts") }
        var dayFile: URL { brain.root.appendingPathComponent("inbox/2026-11-05-instinct.md") }
        var buffer: CaptureBuffer { CaptureBuffer(folder: instinct, now: { now }) }
        var sweep: InstinctSweep {
            InstinctSweep(brainRoot: brain.root, transcriptsFolder: transcripts, instinctFolder: instinct,
                          model: model, now: { now })
        }
        func addTranscript(_ name: String = InstinctSweepTests.transcriptName, text: String = TranscriptSourceTests.transcript()) throws {
            try brain.write("transcripts/\(name)", text)
        }
        func dictate(_ text: String, app: String = "Notes", bundle: String = "com.apple.Notes") {
            buffer.append(text: text, app: app, bundle: bundle)
        }
        func dayText() -> String { (try? String(contentsOf: dayFile, encoding: .utf8)) ?? "" }
        func run(_ kind: InstinctSweepKind = .scheduled, transcript: URL? = nil) async -> InstinctSweepReport {
            await sweep.run(kind: kind, transcript: transcript, checkpoint: InstinctSweepTests.noCheckpoint)
        }
    }

    static func item(_ cat: InstinctCategory, _ text: String, quote: String, source: String, project: String = "alpha",
                     conf: Double = 0.8, due: String? = nil) -> InstinctItem {
        InstinctItem(category: cat, text: text, owner: nil, due: due, quote: quote, sourceID: source, project: project,
                     confidence: conf, conflicts: nil)
    }

    // F1.12, F1.16, F1.17, F1.18: a todo from a Them block, a decision for alpha, nothing for small talk.
    @Test func meetingBlocksBecomeItems() async throws {
        let f = try Fixture()
        try f.addTranscript()
        let name = Self.transcriptName
        f.model.items = { _ in [
            Self.item(.todo, "Send the deck", quote: "Can you send me the deck by Friday?", source: "\(name)#0", project: "none", conf: 0.82, due: "2026-11-06"),
            Self.item(.decision, "Drop the legacy export", quote: "we drop the legacy export", source: "\(name)#1", conf: 0.88),
        ] }
        let r = await f.run()
        #expect(r.written == 2)
        #expect(r.file == f.dayFile)
        #expect(!r.failed)
        let text = f.dayText()
        #expect(text.contains("- [ ] todo: Send the deck (due: 2026-11-06) → none > \"Can you send me the deck by Friday?\" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:14, Them, 0.82)"))
        #expect(text.contains("- [ ] decision: Drop the legacy export → alpha > \"we drop the legacy export\""))
        #expect(text.contains("Swept 1 meeting, 0 dictations."))
        #expect(InstinctState.load(from: f.instinct).swept == [name])
    }

    // The sweep groups sources into the small parts the model was tuned on: at most 12 sources, 1,500 characters.
    @Test func sweepChunksAreTheModelsSmallParts() {
        let sources = (0..<30).map { InstinctGemmaFixtures.source("s\($0)", .you, String(repeating: "x", count: 200)) }
        let parts = InstinctSweep.chunks(sources)
        #expect(parts.allSatisfy { $0.count <= InstinctRules.chunkMaxSources && $0.reduce(0) { $0 + $1.text.count } <= InstinctRules.chunkLimit })
        #expect(parts.flatMap { $0 }.map(\.id) == sources.map(\.id))
        #expect(parts.count == 5)   // 7 per part by size
        #expect(GemmaInstinctModel.chunks(sources) == parts)
    }

    static func lineCount(_ text: String) -> Int { text.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ] ") }.count }

    /// An extract that finds items by source text.
    static func itemsFrom(_ sources: [InstinctSource], _ make: (InstinctSource) -> [InstinctItem]) -> [InstinctItem] {
        sources.flatMap(make)
    }

    @Test func notABrainFailsAndTouchesNothing() async throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.brain.root.appendingPathComponent("AGENTS.md"))
        f.dictate("remind me to renew the vendor contract")
        let r = await f.run()
        #expect(r.failed)
        #expect(f.model.extractCalls.isEmpty)
        #expect(f.buffer.read().count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.instinct.appendingPathComponent("state.json").path))
    }

    // F1.19, F1.20, F1.21: quote not found, no project, low confidence; an unknown project becomes none.
    @Test func validationAndGate() async throws {
        let f = try Fixture()
        f.dictate("remind me to renew the vendor contract by Friday")
        f.model.items = { s in
            let id = s[0].id
            return [
                Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: id, project: "ghost", conf: 0.8),
                Self.item(.todo, "Invented", quote: "never said this", source: id),
                Self.item(.todo, "Wrong source", quote: "renew the vendor", source: "elsewhere#9"),
                Self.item(.fact, "Vendor is Acme", quote: "the vendor contract", source: id, project: "ghost", conf: 0.9),
                Self.item(.decision, "Weak decision", quote: "by Friday", source: id, conf: 0.6),
            ]
        }
        let r = await f.run()
        #expect(r.written == 1)
        #expect(r.dropped.quoteNotFound == 2)
        #expect(r.dropped.noProject == 1)
        #expect(r.dropped.lowConfidence == 1)
        #expect(f.dayText().contains("- [ ] todo: Renew the vendor contract → none >"))
        #expect(f.dayText().contains("1 no project, 1 low confidence, 0 duplicate, 2 quote not found"))
    }

    // F1.15, F1.34: dictations dropped by the prefilter count, and every buffer line read is deleted.
    @Test func dictationSweepDeletesEveryLineRead() async throws {
        let f = try Fixture()
        f.dictate("ok")
        f.dictate("remind me to renew the vendor contract")
        f.dictate("just chatting about lunch plans today")
        f.model.items = { s in
            s.filter { $0.text.hasPrefix("remind") }.map { Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: $0.id) }
        }
        let r = await f.run()
        #expect(r.dropped.byRules == 1)
        #expect(f.model.extractCalls.flatMap { $0 }.count == 2)
        #expect(f.buffer.read().isEmpty)
        #expect(f.dayText().contains("Swept 0 meetings, 3 dictations. Dropped: 1 by rules"))
        #expect(f.dayText().contains("(Notes 2026-11-05 12:00, 0.80)"))
    }

    // F1.30, F1.34: no items writes nothing; sources still count as swept.
    @Test func noItemsWritesNothingButSweeps() async throws {
        let f = try Fixture()
        try f.addTranscript()
        f.dictate("how was your weekend everyone")
        let r = await f.run()
        #expect(r.written == 0 && r.file == nil && !r.failed)
        #expect(!FileManager.default.fileExists(atPath: f.dayFile.path))
        #expect(InstinctState.load(from: f.instinct).swept == [Self.transcriptName])
        #expect(f.buffer.read().isEmpty)
    }

    // State: transcripts older than enabledAt are recorded unread; enabledAt and lastSweep are left alone.
    @Test func recordsOldTranscriptsAndKeepsSchedulerFields() async throws {
        let f = try Fixture()
        try f.addTranscript()
        let enabled = TranscriptSourceTests.local("2026-11-05 11:00")
        try InstinctState(enabledAt: enabled, swept: ["old.md"], lastSweep: nil).save(to: f.instinct)
        try f.addTranscript("2026-11-05 11-30.md", text: TranscriptSourceTests.transcript(start: "11:30", end: "11:50"))
        try f.addTranscript("2026-11-04 09-00.md", text: TranscriptSourceTests.transcript(date: "2026-11-04", start: "09:00", end: "09:30"))
        _ = await f.run()
        let st = InstinctState.load(from: f.instinct)
        #expect(Set(st.swept) == ["old.md", "2026-11-04 09-00.md", Self.transcriptName, "2026-11-05 11-30.md"])
        #expect(st.enabledAt == enabled && st.lastSweep == nil)
        #expect(f.model.extractCalls.flatMap { $0 }.allSatisfy { $0.id.hasPrefix("2026-11-05 11-30.md") })
    }

    // A meeting sweep reads only its own file and leaves the buffer alone.
    @Test func meetingSweepReadsOnlyItsFile() async throws {
        let f = try Fixture()
        try f.addTranscript()
        try f.addTranscript("2026-11-05 11-30.md", text: TranscriptSourceTests.transcript(start: "11:30", end: "11:50"))
        f.dictate("remind me to renew the vendor contract")
        f.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "we drop the legacy export", source: s[1].id)] }
        let r = await f.run(.meeting, transcript: f.transcripts.appendingPathComponent(Self.transcriptName))
        #expect(r.written == 1)
        #expect(f.model.extractCalls.flatMap { $0 }.allSatisfy { $0.id.hasPrefix(Self.transcriptName) })
        #expect(f.dayText().contains("## 12:00 meeting"))
        #expect(f.dayText().contains("Swept 1 meeting, 0 dictations."))
        #expect(InstinctState.load(from: f.instinct).swept == [Self.transcriptName])
        #expect(f.buffer.read().count == 1)
    }

    @Test func meetingSweepOfUnknownFileDoesNothing() async throws {
        let f = try Fixture()
        try f.addTranscript(text: TranscriptSourceTests.transcript(end: nil))
        let r = await f.run(.meeting, transcript: f.transcripts.appendingPathComponent(Self.transcriptName))
        #expect(r == InstinctSweepReport())
        #expect(f.model.extractCalls.isEmpty)
    }

    // F1.32: a chunk is retried once; a second failure counts unreadable and the sweep goes on.
    @Test func chunksRetryOnceThenSkip() async throws {
        let f = try Fixture()
        let filler = String(repeating: "word ", count: 1400)   // 7000 characters
        f.dictate("remind me to renew the vendor contract \(filler)")
        f.dictate("we decided to drop the legacy export \(filler)")
        f.model.items = { s in
            s[0].text.hasPrefix("we decided")
                ? [Self.item(.decision, "Drop the legacy export", quote: "drop the legacy export", source: s[0].id)] : []
        }
        f.model.extractFailures = 2   // both attempts on the first chunk
        var r = await f.run()
        #expect(f.model.extractCalls.count == 3)
        #expect(f.model.extractCalls.allSatisfy { $0.reduce(0) { $0 + $1.text.count } <= max(InstinctRules.chunkLimit, $0[0].text.count) && $0.count <= InstinctRules.chunkMaxSources })
        #expect(r.dropped.unreadable == 1)
        #expect(r.written == 1)

        let g = try Fixture()
        g.dictate("we decided to drop the legacy export")
        g.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "drop the legacy export", source: s[0].id)] }
        g.model.extractFailures = 1
        r = await g.run()
        #expect(g.model.extractCalls.count == 2)
        #expect(r.dropped.unreadable == 0 && r.written == 1)
    }

    // The checkpoint runs before every model call.
    @Test func checkpointBeforeEveryModelCall() async throws {
        let f = try Fixture()
        f.dictate("we decided to drop the legacy export")
        f.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "drop the legacy export", source: s[0].id)] }
        f.model.verdict = .new
        let log = f.model.log
        _ = await f.sweep.run(kind: .scheduled, transcript: nil, checkpoint: { log.events.append("checkpoint") })
        let events = log.events
        #expect(events.contains("extract"))
        for (i, e) in events.enumerated() where e == "extract" || e == "judge" { #expect(i > 0 && events[i - 1] == "checkpoint") }
    }

    // F1.22, F1.25, F1.26 inside a sweep: duplicates of the brain and of earlier items are counted, conflicts are marked.
    @Test func duplicatesAreDroppedAndConflictsMarked() async throws {
        let f = try Fixture()
        f.dictate("send the deck to the board and launch moved to June")
        f.model.verdict = .conflicts("Launch in April")
        f.model.items = { s in
            let id = s[0].id
            return [
                Self.item(.todo, "Send the deck to the board owner Sam due 2026-11-10", quote: "send the deck to the board", source: id),
                Self.item(.fact, "Launch moved to June", quote: "launch moved to June", source: id),
                Self.item(.fact, "Launch moved to June", quote: "launch moved to June", source: id),
                Self.item(.fact, "Launch moved to June", quote: "launch moved to June", source: id),
            ]
        }
        let r = await f.run()
        #expect(r.dropped.duplicate == 3)
        #expect(r.written == 1)
        #expect(f.dayText().contains("conflicts: \"Launch in April\""))
    }

    // F1.27: 14 items pass, the 10 most confident are written, 4 are below the cut.
    @Test func perSweepCutKeepsMostConfident() async throws {
        let f = try Fixture()
        f.dictate("remind me about all of these fourteen things today")
        let words = ["apple", "bridge", "candle", "dragon", "engine", "forest", "garden", "harbor", "island", "jacket", "kettle", "ladder", "marble", "needle"]
        f.model.items = { s in
            words.enumerated().map { i, w in Self.item(.todo, "Prepare \(w)", quote: "remind me", source: s[0].id, conf: 0.5 + Double(i) * 0.02) }
        }
        let r = await f.run()
        #expect(r.written == 10 && r.dropped.belowCut == 4)
        let text = f.dayText()
        #expect(Self.lineCount(text) == 10)
        for w in words.prefix(4) { #expect(!text.contains("Prepare \(w)")) }
        for w in words.suffix(10) { #expect(text.contains("Prepare \(w)")) }
    }

    // F1.28: the day file already holds 25 items; nothing is written, sources count as swept.
    @Test func dailyCapWritesNothing() async throws {
        let f = try Fixture()
        let lines = (0..<25).map { "- [ ] todo: Thing\($0) → none > \"q\" (Notes 2026-11-05 09:00, 0.80)" }
        try f.brain.write("inbox/2026-11-05-instinct.md", "---\ntype: capture\ndescription: \"x\"\nupdated: 2026-11-05\n---\n\n## 09:00\n" + lines.joined(separator: "\n") + "\n")
        try f.addTranscript()
        f.dictate("remind me to renew the vendor contract")
        f.model.items = { s in [Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id)] }
        let r = await f.run()
        #expect(r.capReached && r.written == 0 && r.file == nil && !r.failed)
        #expect(f.model.extractCalls.isEmpty)
        #expect(Self.lineCount(f.dayText()) == 25)
        #expect(InstinctState.load(from: f.instinct).swept == [Self.transcriptName])
        #expect(f.buffer.read().isEmpty)
    }

    @Test func dailyCapLimitsToRemaining() async throws {
        let f = try Fixture()
        let lines = (0..<24).map { "- [ ] todo: Thing\($0) → none > \"q\" (Notes 2026-11-05 09:00, 0.80)" }
        try f.brain.write("inbox/2026-11-05-instinct.md", "---\ntype: capture\ndescription: \"x\"\nupdated: 2026-11-05\n---\n\n## 09:00\n" + lines.joined(separator: "\n") + "\n")
        f.dictate("remind me to renew the vendor contract and drop export")
        f.model.items = { s in [
            Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id, conf: 0.6),
            Self.item(.todo, "Drop export", quote: "drop export", source: s[0].id, conf: 0.9),
        ] }
        let r = await f.run()
        #expect(r.written == 1 && r.dropped.belowCut == 1 && !r.capReached)
        #expect(f.dayText().contains("Drop export"))
    }

    // F1.33: a write failure changes neither buffer nor state.
    @Test func writeFailureLeavesBufferAndState() async throws {
        let f = try Fixture()
        try f.brain.write("inbox/2026-11-05-instinct.md/blocker", "x")   // the day file path is a folder: it cannot be written
        try f.addTranscript()
        f.dictate("remind me to renew the vendor contract")
        f.model.items = { s in [Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s.last!.id)] }
        let r = await f.run()
        #expect(r.failed)
        #expect(f.buffer.read().count == 1)
        #expect(InstinctState.load(from: f.instinct).swept.isEmpty)
    }

    // F1.33: a crash between write and state; the rerun drops the repeats as duplicates of the day file.
    @Test func rerunAfterCrashDropsRepeats() async throws {
        let f = try Fixture()
        f.dictate("remind me to renew the vendor contract")
        f.model.items = { s in [Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id)] }
        let first = await f.run()
        #expect(first.written == 1)
        // Simulate the crash: state and buffer as before the sweep.
        try? FileManager.default.removeItem(at: f.instinct.appendingPathComponent("state.json"))
        f.dictate("remind me to renew the vendor contract")
        let again = await f.run()
        #expect(again.written == 0 && again.dropped.duplicate == 1)
        #expect(Self.lineCount(f.dayText()) == 1)
    }
}
