import Foundation
import Testing
@testable import IonianFlow

// App glue of Aware: folder, capture decision (F1.1 to F1.4), enabledAt (F1.35), pause, menu strings
// (F1.28, F1.31), the adapter from AwareSweep to the scheduler, and SC4 (nothing outside inbox/ changes).
extension IonianFlowTests {
@Suite struct AwareAppTests {
    static let now = TranscriptSourceTests.local("2026-11-05 12:00")
    static let notes = (name: "Notes", bundle: "com.apple.Notes")

    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("aware-app-\(UUID().uuidString)") }

    // Folder resolution.
    @Test func folderUnderTestDirOrApplicationSupport() {
        let t = URL(fileURLWithPath: "/tmp/flow-test", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(AwareApp.folder(testDir: t, home: home).path == "/tmp/flow-test/Aware")
        #expect(AwareApp.folder(testDir: nil, home: home).path == "/Users/someone/Library/Application Support/Ionian Flow/Aware")
    }

    // F1.1: a dictation in Notes is stored with app, bundle and the delivered text.
    @Test func captureStoresDelivered() {
        let folder = tmp(); defer { try? FileManager.default.removeItem(at: folder) }
        let buffer = CaptureBuffer(folder: folder, now: { Self.now })
        let stored = AwareApp.capture(text: "Remind me to renew the vendor contract by Friday", front: Self.notes,
                                         excluded: AwareRules.defaultExcludedApps, secureInput: false, pausedUntil: nil,
                                         now: Self.now, buffer: buffer)
        #expect(stored)
        let e = buffer.read()
        #expect(e.count == 1 && e[0].app == "Notes" && e[0].bundle == "com.apple.Notes")
        #expect(e[0].text == "Remind me to renew the vendor contract by Friday")
    }

    // F1.2: an excluded app, F1.3: secure input, F1.4: paused; nothing stored. No front app or empty text: nothing either.
    @Test func captureRefusals() {
        let folder = tmp(); defer { try? FileManager.default.removeItem(at: folder) }
        let buffer = CaptureBuffer(folder: folder, now: { Self.now })
        let text = "Remind me to renew the vendor contract by Friday"
        let excl = AwareRules.defaultExcludedApps
        #expect(!AwareApp.capture(text: text, front: (name: "1Password", bundle: "com.1password.1password"), excluded: excl,
                                     secureInput: false, pausedUntil: nil, now: Self.now, buffer: buffer))
        #expect(!AwareApp.capture(text: text, front: Self.notes, excluded: excl, secureInput: true,
                                     pausedUntil: nil, now: Self.now, buffer: buffer))
        #expect(!AwareApp.capture(text: text, front: Self.notes, excluded: excl, secureInput: false,
                                     pausedUntil: Self.now.addingTimeInterval(1800), now: Self.now, buffer: buffer))
        #expect(!AwareApp.capture(text: text, front: nil, excluded: excl, secureInput: false, pausedUntil: nil, now: Self.now, buffer: buffer))
        #expect(!AwareApp.capture(text: "", front: Self.notes, excluded: excl, secureInput: false, pausedUntil: nil, now: Self.now, buffer: buffer))
        #expect(buffer.read().isEmpty)
        // An elapsed pause stores again.
        #expect(AwareApp.capture(text: text, front: Self.notes, excluded: excl, secureInput: false,
                                    pausedUntil: Self.now.addingTimeInterval(-1), now: Self.now, buffer: buffer))
    }

    // F1.35: turning on sets enabledAt; off and on moves it; swept and lastSweep stay.
    @Test func enableSetsAndMovesEnabledAt() throws {
        let folder = tmp(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = Self.now, later = Self.now.addingTimeInterval(86_400)
        AwareApp.enable(folder: folder, now: first)
        #expect(AwareState.load(from: folder).enabledAt == first)
        var s = AwareState.load(from: folder)
        s.swept = ["a.md"]; s.lastSweep = first
        try s.save(to: folder)
        AwareApp.enable(folder: folder, now: later)
        let after = AwareState.load(from: folder)
        #expect(after.enabledAt == later && after.swept == ["a.md"] && after.lastSweep == first)
    }

    // F1.4: the pause lasts one hour.
    @Test func pauseIsOneHour() {
        #expect(AwareApp.pauseEnd(from: Self.now) == Self.now.addingTimeInterval(3600))
        #expect(!AwareRules.shouldCapture(bundle: "com.apple.Notes", excluded: [], secureInput: false,
                                             pausedUntil: AwareApp.pauseEnd(from: Self.now), now: Self.now.addingTimeInterval(3599)))
        #expect(AwareRules.shouldCapture(bundle: "com.apple.Notes", excluded: [], secureInput: false,
                                            pausedUntil: AwareApp.pauseEnd(from: Self.now), now: Self.now.addingTimeInterval(3601)))
    }

    // F1.28, F1.31: menu strings and General page copy are plain.
    @Test func menuAndCopy() {
        #expect(AwareApp.menuLines(status: nil) == (nil, ["Sweep now", "Pause Aware for 1 hour"]))
        #expect(AwareApp.menuLines(status: "Aware: daily cap reached").status == "Aware: daily cap reached")
        for s in [AwareApp.sweepNowTitle, AwareApp.pauseTitle] { #expect(!s.contains("!") && !s.contains("\u{2014}")) }
    }

    // The app ships with the Gemma model plugged in.
    @Test func gemmaIsPluggedIn() throws {
        let make = try #require(AwareApp.makeModel)
        #expect(make(SweepControl()) is GemmaAwareModel)
    }

    // Without a model factory the app reports "model not downloaded".
    @Test func liveSweepNeedsModelFactory() {
        let saved = AwareApp.makeModel
        defer { AwareApp.makeModel = saved }
        AwareApp.makeModel = nil
        #expect(AwareApp.liveSweep(SweepControl()) == nil)
    }

    // MARK: adapter

    final class Box: @unchecked Sendable { let sweep: AwareSweep; init(_ s: AwareSweep) { sweep = s } }

    struct Rig {
        let brain: FixtureBrain
        let aware: URL
        let model = FakeAwareModel()
        init() throws {
            brain = try FixtureBrain()
            try brain.write("projects/alpha.md", FixtureBrain.alpha)
            aware = FileManager.default.temporaryDirectory.appendingPathComponent("aware-rig-\(UUID().uuidString)")
        }
        var transcripts: URL { brain.root.appendingPathComponent("transcripts") }
        var buffer: CaptureBuffer { CaptureBuffer(folder: aware, now: { AwareAppTests.now }) }
        var adapter: AwareSweepAdapter {
            let box = Box(AwareSweep(brainRoot: brain.root, transcriptsFolder: transcripts, awareFolder: aware,
                                        model: model, now: { AwareAppTests.now }))
            return AwareSweepAdapter(build: { _ in box.sweep })
        }
    }

    // .scheduled runs the dictation sweep and reports done.
    @Test func adapterScheduledReadsBuffer() async throws {
        let r = try Rig()
        r.buffer.append(text: "remind me to renew the vendor contract", app: "Notes", bundle: "com.apple.Notes")
        r.model.items = { s in [AwareSweepTests.item(.todo, "Renew the vendor contract", quote: "renew the vendor contract", source: s[0].id)] }
        let outcome = await r.adapter.run(.scheduled, gate: AwareGate())
        #expect(outcome == .done(capReached: false))
        #expect(r.model.extractCalls.count == 1)
        let day = try String(contentsOf: r.brain.root.appendingPathComponent("inbox/2026-11-05-aware.md"), encoding: .utf8)
        #expect(day.contains("Renew the vendor contract") && !day.contains("## 12:00 meeting"))
    }

    // .meeting(url) runs a meeting sweep of that file only; the dictation buffer stays.
    @Test func adapterMeetingReadsOneFile() async throws {
        let r = try Rig()
        try r.brain.write("transcripts/2026-11-05 10-02.md", TranscriptSourceTests.transcript())
        r.buffer.append(text: "remind me to renew the vendor contract", app: "Notes", bundle: "com.apple.Notes")
        r.model.items = { s in [AwareSweepTests.item(.todo, "Send the deck", quote: "Can you send me the deck", source: s[0].id, project: "none")] }
        let url = r.transcripts.appendingPathComponent("2026-11-05 10-02.md")
        let outcome = await r.adapter.run(.meeting(url), gate: AwareGate())
        #expect(outcome == .done(capReached: false))
        let day = try String(contentsOf: r.brain.root.appendingPathComponent("inbox/2026-11-05-aware.md"), encoding: .utf8)
        #expect(day.contains("## 12:00 meeting"))
        #expect(r.buffer.read().count == 1)
        #expect(r.model.extractCalls.allSatisfy { $0.allSatisfy { if case .transcript = $0.kind { true } else { false } } })
    }

    // A failed report is .failed; no sweep to build (no model, no brain) is .failed; a reached cap is passed on.
    @Test func adapterMapsFailureAndCap() async throws {
        let r = try Rig()
        try FileManager.default.removeItem(at: r.brain.root.appendingPathComponent("inbox"))  // no longer a brain
        #expect(await r.adapter.run(.scheduled, gate: AwareGate()) == .failed)
        #expect(await AwareSweepAdapter(build: { _ in nil }).run(.scheduled, gate: AwareGate()) == .failed)

        let c = try Rig()
        let lines = (0..<25).map { "- [ ] todo: Thing\($0) → none > \"q\" (Notes 2026-11-05 09:00, 0.80)" }
        try c.brain.write("inbox/2026-11-05-aware.md", "---\ntype: capture\ndescription: \"x\"\nupdated: 2026-11-05\n---\n\n## 09:00\n" + lines.joined(separator: "\n") + "\n")
        #expect(await c.adapter.run(.scheduled, gate: AwareGate()) == .done(capReached: true))
    }

    // The sweep builds with the gate's control, so the model can check it per token.
    @Test func adapterPassesGateControl() async {
        final class Seen: @unchecked Sendable { var control: SweepControl? }
        let seen = Seen(), gate = AwareGate()
        _ = await AwareSweepAdapter(build: { seen.control = $0; return nil }).run(.scheduled, gate: gate)
        #expect(seen.control === gate.control)
    }

    // MARK: SC4

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for rel in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDir)
            out[rel] = isDir.boolValue ? Data("<dir>".utf8) : try Data(contentsOf: root.appendingPathComponent(rel))
        }
        return out
    }

    // SC4: ten sweeps change nothing in the brain outside inbox/.
    @Test func tenSweepsOnlyTouchInbox() async throws {
        let r = try Rig()
        try r.brain.write("logs/alpha.md", "# Alpha log\n- 2026-11-01 Kickoff\n")
        try r.brain.write("index.md", "# Brain\n")
        try r.brain.write("transcripts/2026-11-05 10-02.md", TranscriptSourceTests.transcript())
        let before = try snapshot(r.brain.root).filter { !$0.key.hasPrefix("inbox") }
        let adapter = r.adapter
        r.model.items = { s in s.prefix(1).map { AwareSweepTests.item(.todo, "Prepare \($0.text)", quote: $0.text, source: $0.id, project: "alpha") } }
        let url = r.transcripts.appendingPathComponent("2026-11-05 10-02.md")
        let words = ["apple", "birch", "cedar", "dune", "ember", "fjord", "grove", "heron", "iris", "juniper"]
        for (i, w) in words.enumerated() {
            r.buffer.append(text: "remind me to prepare the \(w) report", app: "Notes", bundle: "com.apple.Notes")
            let request: AwareSweepRequest = i == 3 ? .meeting(url) : .scheduled
            let outcome = await adapter.run(request, gate: AwareGate())
            #expect(outcome != .failed)
        }
        let after = try snapshot(r.brain.root).filter { !$0.key.hasPrefix("inbox") }
        #expect(before == after)
        #expect(!before.isEmpty)
        let inbox = try snapshot(r.brain.root).keys.filter { $0.hasPrefix("inbox/") && $0.hasSuffix("-aware.md") }
        #expect(!inbox.isEmpty)
    }
}
}
