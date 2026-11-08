import Foundation
import Testing
@testable import IonianFlow

@Suite struct AwareSweepTests {
    static let noCheckpoint: () async -> Void = {}
    static let transcriptName = "2026-11-05 10-02.md"

    struct Fixture {
        let brain: FixtureBrain
        let aware: URL
        let model = FakeAwareModel()
        let now = TranscriptSourceTests.local("2026-11-05 12:00")

        init() throws {
            brain = try FixtureBrain()
            try brain.write("projects/alpha.md", FixtureBrain.alpha)
            aware = FileManager.default.temporaryDirectory.appendingPathComponent("aware-\(UUID().uuidString)")
        }
        var transcripts: URL { brain.root.appendingPathComponent("transcripts") }
        var dayFile: URL { brain.root.appendingPathComponent("inbox/2026-11-05-aware.md") }
        var sweep: AwareSweep {
            AwareSweep(brainRoot: brain.root, transcriptsFolder: transcripts, awareFolder: aware,
                          model: model, now: { now })
        }
        func addTranscript(_ name: String = AwareSweepTests.transcriptName, text: String = TranscriptSourceTests.transcript()) throws {
            try brain.write("transcripts/\(name)", text)
        }
        /// A meeting of one block that someone else said; the files sort in the order of the calls.
        func speak(_ text: String) {
            let n = ((try? FileManager.default.contentsOfDirectory(atPath: transcripts.path)) ?? []).filter { $0.hasPrefix("2026-11-05 09-") }.count
            let name = String(format: "2026-11-05 09-%02d.md", n)
            try? brain.write("transcripts/\(name)", TranscriptSourceTests.transcript(start: "09:00", end: "09:30", body: [text]))
        }
        func dayText() -> String { (try? String(contentsOf: dayFile, encoding: .utf8)) ?? "" }
        func run(_ kind: AwareSweepKind = .catchUp, transcript: URL? = nil) async -> AwareSweepReport {
            await sweep.run(kind: kind, transcript: transcript, checkpoint: AwareSweepTests.noCheckpoint)
        }
    }

    static func item(_ cat: AwareCategory, _ text: String, quote: String, source: String, project: String = "alpha",
                     conf: Double = 0.8, due: String? = nil) -> AwareItem {
        AwareItem(category: cat, text: text, owner: nil, due: due, quote: quote, sourceID: source, project: project,
                     confidence: conf, conflicts: nil)
    }

    // F1.12, F1.16, F1.17, F1.18: a todo from a Them block, a decision for alpha, nothing for small talk.
    @Test func meetingBlocksBecomeItems() async throws {
        let f = try Fixture()
        try f.addTranscript()
        let name = Self.transcriptName
        f.model.items = { _ in [
            Self.item(.todo, "Send the deck", quote: "Can you send me the deck by Friday?", source: "\(name)#0", project: "none", conf: 0.82, due: "2026-11-06"),
            Self.item(.decision, "Drop the legacy export", quote: "we drop the legacy export, that's decided", source: "\(name)#1", conf: 0.88),
        ] }
        let r = await f.run()
        #expect(r.written == 2)
        #expect(r.file == f.dayFile)
        #expect(!r.failed)
        let text = f.dayText()
        #expect(text.contains("- [ ] todo: Send the deck (due: 2026-11-06) → none > \"Can you send me the deck by Friday?\" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:14, Them, 0.82)"))
        #expect(text.contains("- [ ] decision: Drop the legacy export → alpha > \"we drop the legacy export, that's decided\""))
        #expect(text.contains("Swept 1 meeting."))
        #expect(AwareState.load(from: f.aware).swept == [name])
    }

    // The sweep groups sources into the small parts the model was tuned on: at most 12 sources, 1,500 characters.
    @Test func sweepChunksAreTheModelsSmallParts() {
        let sources = (0..<30).map { AwareGemmaFixtures.source("s\($0)", .you, String(repeating: "x", count: 200)) }
        let parts = AwareSweep.chunks(sources)
        #expect(parts.allSatisfy { $0.count <= AwareRules.chunkMaxSources && $0.reduce(0) { $0 + $1.text.count } <= AwareRules.chunkLimit })
        #expect(parts.flatMap { $0 }.map(\.id) == sources.map(\.id))
        #expect(parts.count == 5)   // 7 per part by size
        #expect(GemmaAwareModel.chunks(sources) == parts)
    }

    // F1.42: a catch-up reads every pending transcript and records the older ones unread.
    @Test func catchUpReadsAllPendingTranscripts() async throws {
        let f = try Fixture()
        try f.addTranscript()
        try f.addTranscript("2026-11-05 11-30.md", text: TranscriptSourceTests.transcript(start: "11:30", end: "11:50"))
        try AwareState(enabledAt: TranscriptSourceTests.local("2026-11-05 10:00"), swept: []).save(to: f.aware)
        try f.addTranscript("2026-11-05 08-00.md", text: TranscriptSourceTests.transcript(start: "08:00", end: "08:30"))
        f.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "we drop the legacy export, that's decided", source: s[1].id)] }
        let r = await f.run(.catchUp)
        #expect(r.written >= 1 && !r.failed)
        let text = f.dayText()
        #expect(text.contains("## 12:00\n"))
        #expect(text.contains("Swept 2 meetings. Dropped:"))
        #expect(Set(AwareState.load(from: f.aware).swept) == ["2026-11-05 08-00.md", Self.transcriptName, "2026-11-05 11-30.md"])
        #expect(AwareState.load(from: f.aware).lastResult?.meetings == 2)
    }

    // F1.38: when every part is unreadable nothing is marked swept, so the next catch-up reads it again.
    @Test func allPartsUnreadableMarksNothingSwept() async throws {
        let f = try Fixture()
        try f.addTranscript()
        f.model.extractFailures = 10
        let r = await f.run(.catchUp)
        #expect(r.failed)
        #expect(AwareState.load(from: f.aware).swept.isEmpty)
        #expect(AwareState.load(from: f.aware).lastResult?.failed == true)
    }

    static func lineCount(_ text: String) -> Int { text.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ] ") }.count }

    /// An extract that finds items by source text.
    static func itemsFrom(_ sources: [AwareSource], _ make: (AwareSource) -> [AwareItem]) -> [AwareItem] {
        sources.flatMap(make)
    }

    @Test func notABrainFailsAndTouchesNothing() async throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.brain.root.appendingPathComponent("AGENTS.md"))
        try f.addTranscript()
        let r = await f.run()
        #expect(r.failed)
        #expect(f.model.extractCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.aware.appendingPathComponent("state.json").path))
    }

    // F1.19, F1.20, F1.21: quote not found, no project, low confidence; an unknown project becomes none.
    @Test func validationAndGate() async throws {
        let f = try Fixture()
        f.speak("remind me to renew the vendor contract by Friday")
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

    // F1.30, F1.34: no items writes nothing; sources still count as swept.
    @Test func noItemsWritesNothingButSweeps() async throws {
        let f = try Fixture()
        try f.addTranscript()
        let r = await f.run()
        #expect(r.written == 0 && r.file == nil && !r.failed)
        #expect(!FileManager.default.fileExists(atPath: f.dayFile.path))
        #expect(AwareState.load(from: f.aware).swept == [Self.transcriptName])
    }

    // State: transcripts older than enabledAt are recorded unread; enabledAt is left alone.
    @Test func recordsOldTranscriptsAndKeepsEnabledAt() async throws {
        let f = try Fixture()
        try f.addTranscript()
        let enabled = TranscriptSourceTests.local("2026-11-05 11:00")
        try AwareState(enabledAt: enabled, swept: ["old.md"]).save(to: f.aware)
        try f.addTranscript("2026-11-05 11-30.md", text: TranscriptSourceTests.transcript(start: "11:30", end: "11:50"))
        try f.addTranscript("2026-11-04 09-00.md", text: TranscriptSourceTests.transcript(date: "2026-11-04", start: "09:00", end: "09:30"))
        _ = await f.run()
        let st = AwareState.load(from: f.aware)
        #expect(Set(st.swept) == ["old.md", "2026-11-04 09-00.md", Self.transcriptName, "2026-11-05 11-30.md"])
        #expect(st.enabledAt == enabled)
        #expect(f.model.extractCalls.flatMap { $0 }.allSatisfy { $0.id.hasPrefix("2026-11-05 11-30.md") })
    }

    // A meeting sweep reads only its own file.
    @Test func meetingSweepReadsOnlyItsFile() async throws {
        let f = try Fixture()
        try f.addTranscript()
        try f.addTranscript("2026-11-05 11-30.md", text: TranscriptSourceTests.transcript(start: "11:30", end: "11:50"))
        f.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "we drop the legacy export, that's decided", source: s[1].id)] }
        let r = await f.run(.meeting, transcript: f.transcripts.appendingPathComponent(Self.transcriptName))
        #expect(r.written == 1)
        #expect(f.model.extractCalls.flatMap { $0 }.allSatisfy { $0.id.hasPrefix(Self.transcriptName) })
        #expect(f.dayText().contains("## 12:00 meeting"))
        #expect(f.dayText().contains("Swept 1 meeting."))
        #expect(AwareState.load(from: f.aware).swept == [Self.transcriptName])
    }

    @Test func meetingSweepOfUnknownFileDoesNothing() async throws {
        let f = try Fixture()
        try f.addTranscript(text: TranscriptSourceTests.transcript(end: nil))
        let r = await f.run(.meeting, transcript: f.transcripts.appendingPathComponent(Self.transcriptName))
        #expect(r == AwareSweepReport())
        #expect(f.model.extractCalls.isEmpty)
    }

    // F1.32: a chunk is retried once; a second failure counts unreadable and the sweep goes on.
    @Test func chunksRetryOnceThenSkip() async throws {
        let f = try Fixture()
        let filler = String(repeating: "word ", count: 1400)   // 7000 characters
        f.speak("remind me to renew the vendor contract \(filler)")
        f.speak("we decided to drop the legacy export \(filler)")
        f.model.items = { s in
            s[0].text.hasPrefix("we decided")
                ? [Self.item(.decision, "Drop the legacy export", quote: "we decided to drop the legacy export", source: s[0].id)] : []
        }
        f.model.extractFailures = 2   // both attempts on the first chunk
        var r = await f.run()
        #expect(f.model.extractCalls.count == 3)
        #expect(f.model.extractCalls.allSatisfy { $0.reduce(0) { $0 + $1.text.count } <= max(AwareRules.chunkLimit, $0[0].text.count) && $0.count <= AwareRules.chunkMaxSources })
        #expect(r.dropped.unreadable == 1)
        #expect(r.written == 1)

        let g = try Fixture()
        g.speak("we decided to drop the legacy export")
        g.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "we decided to drop the legacy export", source: s[0].id)] }
        g.model.extractFailures = 1
        r = await g.run()
        #expect(g.model.extractCalls.count == 2)
        #expect(r.dropped.unreadable == 0 && r.written == 1)
    }

    // The checkpoint runs before every model call.
    @Test func checkpointBeforeEveryModelCall() async throws {
        let f = try Fixture()
        f.speak("we decided to drop the legacy export")
        f.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "we decided to drop the legacy export", source: s[0].id)] }
        f.model.verdict = .new
        let log = f.model.log
        _ = await f.sweep.run(kind: .catchUp, transcript: nil, checkpoint: { log.events.append("checkpoint") })
        let events = log.events
        #expect(events.contains("extract"))
        for (i, e) in events.enumerated() where e == "extract" || e == "judge" || e == "verify" { #expect(i > 0 && events[i - 1] == "checkpoint") }
    }

    // The verification call: after the gate and before the duplicate check; a "no" or an error drops the candidate
    // (counted as low confidence); a wrong project turns the project into none, which the gate then applies again.
    @Test func verifyDropsCandidatesThatDoNotHold() async throws {
        let f = try Fixture()
        f.speak("remind me to renew the vendor contract and the audit is on 3 March")
        f.model.items = { s in [
            Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id),
            Self.item(.fact, "The audit is on 3 March", quote: "the audit is on 3 March", source: s[0].id, conf: 0.9),
        ] }
        f.model.verification = { AwareVerification(holds: $0.category == .todo, belongsToProject: true) }
        let r = await f.run()
        #expect(r.written == 1 && r.dropped.lowConfidence == 1)
        #expect(f.model.verifyCalls.count == 2)
        #expect(f.model.verifyCalls[0].project?.slug == "alpha")
    }

    @Test func verifyErrorKeepsNothing() async throws {
        let f = try Fixture()
        f.speak("remind me to renew the vendor contract")
        f.model.items = { s in [Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id)] }
        f.model.verifyThrows = true
        let r = await f.run()
        #expect(r.written == 0 && r.dropped.lowConfidence == 1)
    }

    @Test func verifyMovesWrongProjectToNoneAndTheGateAppliesAgain() async throws {
        let f = try Fixture()
        f.speak("remind me to renew the vendor contract and we decided to drop the legacy export")
        f.model.items = { s in [
            Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id, project: "alpha"),
            Self.item(.decision, "Drop the legacy export", quote: "we decided to drop the legacy export", source: s[0].id, project: "alpha", conf: 0.9),
        ] }
        f.model.verification = { _ in AwareVerification(holds: true, belongsToProject: false) }
        let r = await f.run()
        #expect(r.written == 1 && r.dropped.noProject == 1)
        #expect(f.dayText().contains("todo: Renew the vendor contract → none >"))
        #expect(f.model.verifyCalls.count == 2)
    }

    @Test func noVerifyForCandidatesTheGateDropped() async throws {
        let f = try Fixture()
        f.speak("remind me to renew the vendor contract")
        f.model.items = { s in [Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id, conf: 0.3)] }
        _ = await f.run()
        #expect(f.model.verifyCalls.isEmpty)
    }

    @Test func quoteWithoutEvidenceIsDroppedByRulesBeforeVerification() async throws {
        let f = try Fixture()
        f.speak("remind me that the wiki diagram is outdated and that I would not want to commit to anything")
        f.model.items = { s in [
            Self.item(.fact, "The diagram is outdated", quote: "the wiki diagram is outdated", source: s[0].id, conf: 0.9),
            Self.item(.decision, "No commitment", quote: "I would not want to commit to anything", source: s[0].id, conf: 0.9),
        ] }
        let r = await f.run()
        #expect(r.written == 0 && r.dropped.byRules == 2)
        #expect(f.model.verifyCalls.isEmpty)
    }

    @Test func weekdayInTheQuoteOverridesTheModelsDue() async throws {
        let f = try Fixture()   // the meeting is on Thursday 2026-11-05
        f.speak("remind me to call the plumber on Monday")
        f.model.items = { s in [Self.item(.todo, "Call the plumber", quote: "call the plumber on Monday", source: s[0].id, due: "2026-11-02")] }
        _ = await f.run()
        #expect(f.dayText().contains("(due: 2026-11-09)"))
    }

    @Test func dueWithoutYearRollsToNextYear() async throws {
        let f = try Fixture()
        f.speak("remind me to file the report by the third of March")
        f.model.items = { s in [Self.item(.todo, "File the report", quote: "file the report by the third of March", source: s[0].id, due: "2026-03-03")] }
        _ = await f.run()
        #expect(f.dayText().contains("(due: 2027-03-03)"))
    }

    // F1.22, F1.25, F1.26 inside a sweep: duplicates of the brain and of earlier items are counted, conflicts are marked.
    @Test func duplicatesAreDroppedAndConflictsMarked() async throws {
        let f = try Fixture()
        f.speak("send the deck to the board and launch moved to June")
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
        f.speak("remind me about all of these fourteen things today")
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
        try f.brain.write("inbox/2026-11-05-aware.md", "---\ntype: capture\ndescription: \"x\"\nupdated: 2026-11-05\n---\n\n## 09:00\n" + lines.joined(separator: "\n") + "\n")
        try f.addTranscript()
        f.model.items = { s in [Self.item(.todo, "Send the deck", quote: "send me the deck", source: s[0].id)] }
        let r = await f.run()
        #expect(r.capReached && r.written == 0 && r.file == nil && !r.failed)
        #expect(f.model.extractCalls.isEmpty)
        #expect(Self.lineCount(f.dayText()) == 25)
        #expect(AwareState.load(from: f.aware).swept == [Self.transcriptName])
    }

    @Test func dailyCapLimitsToRemaining() async throws {
        let f = try Fixture()
        let lines = (0..<24).map { "- [ ] todo: Thing\($0) → none > \"q\" (Notes 2026-11-05 09:00, 0.80)" }
        try f.brain.write("inbox/2026-11-05-aware.md", "---\ntype: capture\ndescription: \"x\"\nupdated: 2026-11-05\n---\n\n## 09:00\n" + lines.joined(separator: "\n") + "\n")
        f.speak("remind me to renew the vendor contract and drop export")
        f.model.items = { s in [
            Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id, conf: 0.6),
            Self.item(.todo, "Drop export", quote: "drop export", source: s[0].id, conf: 0.9),
        ] }
        let r = await f.run()
        #expect(r.written == 1 && r.dropped.belowCut == 1 && !r.capReached)
        #expect(f.dayText().contains("Drop export"))
    }

    // F1.33: a write failure changes no state.
    @Test func writeFailureLeavesState() async throws {
        let f = try Fixture()
        try f.brain.write("inbox/2026-11-05-aware.md/blocker", "x")   // the day file path is a folder: it cannot be written
        try f.addTranscript()
        f.model.items = { s in [Self.item(.decision, "Drop the legacy export", quote: "we drop the legacy export, that's decided", source: s.last!.id)] }
        let r = await f.run()
        #expect(r.failed)
        #expect(AwareState.load(from: f.aware).swept.isEmpty)
    }

    // F1.33: a crash between write and state; the rerun drops the repeats as duplicates of the day file.
    @Test func rerunAfterCrashDropsRepeats() async throws {
        let f = try Fixture()
        f.speak("remind me to renew the vendor contract")
        f.model.items = { s in [Self.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id)] }
        let first = await f.run()
        #expect(first.written == 1)
        // Simulate the crash: the state as before the sweep, so the transcript is pending again.
        try? FileManager.default.removeItem(at: f.aware.appendingPathComponent("state.json"))
        let again = await f.run()
        #expect(again.written == 0 && again.dropped.duplicate == 1)
        #expect(Self.lineCount(f.dayText()) == 1)
    }
}
