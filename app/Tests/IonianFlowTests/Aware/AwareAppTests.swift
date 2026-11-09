import Foundation
import Testing
@testable import IonianFlow

// App glue of Aware: folder, enabledAt (F1.35), notice (F1.41), menu strings
// (F1.28, F1.31), the adapter from AwareSweep to the scheduler, and SC4 (nothing outside inbox/ changes).
extension IonianFlowTests {
@Suite struct AwareAppTests {
    static let now = TranscriptSourceTests.local("2026-11-05 12:00")

    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("aware-app-\(UUID().uuidString)") }

    // Folder resolution.
    @Test func folderUnderTestDirOrApplicationSupport() {
        let t = URL(fileURLWithPath: "/tmp/flow-test", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(AwareApp.folder(testDir: t, home: home).path == "/tmp/flow-test/Aware")
        #expect(AwareApp.folder(testDir: nil, home: home).path == "/Users/someone/Library/Application Support/Ionian Flow/Aware")
    }

    // F1.35: turning on sets enabledAt; off and on moves it; swept stays.
    @Test func enableSetsAndMovesEnabledAt() throws {
        let folder = tmp(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = Self.now, later = Self.now.addingTimeInterval(86_400)
        AwareApp.enable(folder: folder, now: first)
        #expect(AwareState.load(from: folder).enabledAt == first)
        var s = AwareState.load(from: folder)
        s.swept = ["a.md"]
        try s.save(to: folder)
        AwareApp.enable(folder: folder, now: later)
        let after = AwareState.load(from: folder)
        #expect(after.enabledAt == later && after.swept == ["a.md"])
    }

    // F1.28, F1.31: menu strings are plain; when Aware is on the menu holds the status line and Sweep now, nothing else.
    @Test func menuAndCopy() {
        #expect(AwareApp.menuLines(status: nil) == (nil, ["Sweep now"]))
        #expect(AwareApp.menuLines(status: "Aware: daily cap reached") == ("Aware: daily cap reached", ["Sweep now"]))
        #expect(!AwareApp.sweepNowTitle.contains("!") && !AwareApp.sweepNowTitle.contains("\u{2014}"))
    }

    // F1.41: the notice, from counts only.
    @Test func noticeCopy() {
        func result(meetings: Int, written: Int, failed: Bool = false) -> AwareSweepResult {
            AwareSweepResult(at: Self.now, meetings: meetings, written: written, failed: failed)
        }
        #expect(AwareApp.notice(result(meetings: 1, written: 2), manual: false)
                == AwareApp.Notice(title: "Aware wrote 2 proposals to your inbox.", body: "From 1 meeting. Open to review."))
        #expect(AwareApp.notice(result(meetings: 2, written: 1), manual: true)
                == AwareApp.Notice(title: "Aware wrote 1 proposal to your inbox.", body: "From 2 meetings. Open to review."))
        // Only a manual sweep answers with "nothing" or a failure.
        #expect(AwareApp.notice(result(meetings: 0, written: 0), manual: false) == nil)
        #expect(AwareApp.notice(result(meetings: 2, written: 0), manual: false) == nil)
        #expect(AwareApp.notice(result(meetings: 1, written: 0, failed: true), manual: false) == nil)
        #expect(AwareApp.notice(result(meetings: 0, written: 0), manual: true)
                == AwareApp.Notice(title: "Nothing new for Aware to read.", body: "It reads meetings when they end."))
        #expect(AwareApp.notice(result(meetings: 2, written: 0), manual: true)
                == AwareApp.Notice(title: "Aware found nothing to propose.", body: "It read 2 meetings."))
        #expect(AwareApp.notice(result(meetings: 1, written: 0, failed: true), manual: true)
                == AwareApp.Notice(title: "Aware could not read this time.", body: "Nothing was lost. It tries again soon."))
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
        var adapter: AwareSweepAdapter {
            let box = Box(AwareSweep(brainRoot: brain.root, transcriptsFolder: transcripts, awareFolder: aware,
                                        model: model, now: { AwareAppTests.now }))
            return AwareSweepAdapter(build: { _ in box.sweep })
        }
    }

    // .catchUp reads the pending transcripts and reports done.
    @Test func adapterCatchUpReadsPendingTranscripts() async throws {
        let r = try Rig()
        try r.brain.write("transcripts/2026-11-05 10-02.md", TranscriptSourceTests.transcript())
        r.model.items = { s in [AwareSweepTests.item(.todo, "Send the deck", quote: "Can you send me the deck", source: s[0].id, project: "none")] }
        let outcome = await r.adapter.run(.catchUp, gate: AwareGate())
        #expect(outcome == .done(capReached: false))
        #expect(r.model.extractCalls.count == 1)
        let day = try String(contentsOf: r.brain.root.appendingPathComponent("inbox/2026-11-05-aware.md"), encoding: .utf8)
        #expect(day.contains("Send the deck") && day.contains("## 12:00\n") && !day.contains("## 12:00 meeting"))
    }

    // .meeting(url) runs a meeting sweep of that file only.
    @Test func adapterMeetingReadsOneFile() async throws {
        let r = try Rig()
        try r.brain.write("transcripts/2026-11-05 10-02.md", TranscriptSourceTests.transcript())
        try r.brain.write("transcripts/2026-11-05 11-30.md", TranscriptSourceTests.transcript(start: "11:30", end: "11:50"))
        r.model.items = { s in [AwareSweepTests.item(.todo, "Send the deck", quote: "Can you send me the deck", source: s[0].id, project: "none")] }
        let url = r.transcripts.appendingPathComponent("2026-11-05 10-02.md")
        let outcome = await r.adapter.run(.meeting(url), gate: AwareGate())
        #expect(outcome == .done(capReached: false))
        let day = try String(contentsOf: r.brain.root.appendingPathComponent("inbox/2026-11-05-aware.md"), encoding: .utf8)
        #expect(day.contains("## 12:00 meeting"))
        #expect(r.model.extractCalls.allSatisfy { $0.allSatisfy { $0.id.hasPrefix("2026-11-05 10-02.md") } })
    }

    // A failed report is .failed; no sweep to build (no model, no brain) is .failed; a reached cap is passed on.
    @Test func adapterMapsFailureAndCap() async throws {
        let r = try Rig()
        try FileManager.default.removeItem(at: r.brain.root.appendingPathComponent("inbox"))  // no longer a brain
        #expect(await r.adapter.run(.catchUp, gate: AwareGate()) == .failed)
        #expect(await AwareSweepAdapter(build: { _ in nil }).run(.catchUp, gate: AwareGate()) == .failed)

        let c = try Rig()
        let lines = (0..<25).map { "- [ ] todo: Thing\($0) → none > \"q\" (Notes 2026-11-05 09:00, 0.80)" }
        try c.brain.write("inbox/2026-11-05-aware.md", "---\ntype: capture\ndescription: \"x\"\nupdated: 2026-11-05\n---\n\n## 09:00\n" + lines.joined(separator: "\n") + "\n")
        #expect(await c.adapter.run(.catchUp, gate: AwareGate()) == .done(capReached: true))
    }

    // The sweep builds with the gate's control, so the model can check it per token.
    @Test func adapterPassesGateControl() async {
        final class Seen: @unchecked Sendable { var control: SweepControl? }
        let seen = Seen(), gate = AwareGate()
        _ = await AwareSweepAdapter(build: { seen.control = $0; return nil }).run(.catchUp, gate: gate)
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
        // The test adds its own transcripts to the brain below; everything else must stay as it is.
        func untouched(_ d: [String: Data]) -> [String: Data] { d.filter { !$0.key.hasPrefix("inbox") && !$0.key.hasPrefix("transcripts/2026-11-05 09-") } }
        let before = untouched(try snapshot(r.brain.root))
        let adapter = r.adapter
        r.model.items = { s in s.prefix(1).map { AwareSweepTests.item(.todo, "Prepare \($0.text)", quote: $0.text, source: $0.id, project: "alpha") } }
        let words = ["apple", "birch", "cedar", "dune", "ember", "fjord", "grove", "heron", "iris", "juniper"]
        for (i, w) in words.enumerated() {
            let name = "2026-11-05 09-0\(i).md"
            try r.brain.write("transcripts/\(name)", TranscriptSourceTests.transcript(start: "09:0\(i)", end: "09:30", body: ["remind me to prepare the \(w) report"]))
            let request: AwareSweepRequest = i == 3 ? .meeting(r.transcripts.appendingPathComponent(name)) : .catchUp
            let outcome = await adapter.run(request, gate: AwareGate())
            #expect(outcome != .failed)
        }
        let after = untouched(try snapshot(r.brain.root))
        #expect(before == after)
        #expect(!before.isEmpty)
        let inbox = try snapshot(r.brain.root).keys.filter { $0.hasPrefix("inbox/") && $0.hasSuffix("-aware.md") }
        #expect(!inbox.isEmpty)
    }
}
}
