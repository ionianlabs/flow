import Foundation
import Testing
@testable import IonianFlow

// Spec F1.38 to F1.41, F3.16: a sweep says what it did, a model that cannot read loses nothing, what waits is shown (F1.42).
@MainActor @Suite struct AwareFeedbackTests {
    static func at(_ s: String) -> Date { TranscriptSourceTests.local(s) }
    static let brain = URL(fileURLWithPath: "/Users/sample/Ionian/brain", isDirectory: true)
    static let noon = at("2026-11-06 12:00")

    static func page(result: AwareSweepResult? = nil, pending: Int = 0, itemsToday: Int = 0, sweeping: Bool = false) -> AwarePageState {
        var state = AwareState(enabledAt: nil, swept: [])
        state.lastResult = result
        return AwarePageState.make(settings: AwarePageSettings(on: true), brain: brain,
                                      cleanupInstalled: true, state: state, now: at("2026-11-06 13:10"), itemsToday: itemsToday,
                                      pending: pending, sweeping: sweeping, home: "/h")
    }

    static func result(meetings: Int = 0, written: Int = 0, failed: Bool = false) -> AwareSweepResult {
        AwareSweepResult(at: noon, meetings: meetings, written: written, failed: failed)
    }

    // F1.39: a meeting started in the minute Aware was turned on is read (the file only stores the minute).
    @Test func meetingInTheMinuteOfEnablingIsRead() throws {
        let dir = try TranscriptSourceTests.tmp()
        try TranscriptSourceTests.transcript(start: "07:59").write(to: dir.appendingPathComponent("before.md"), atomically: true, encoding: .utf8)
        try TranscriptSourceTests.transcript(start: "08:00").write(to: dir.appendingPathComponent("same.md"), atomically: true, encoding: .utf8)
        var state = AwareState()
        state.enabledAt = Self.at("2026-11-05 08:00").addingTimeInterval(24)
        let p = TranscriptSource.pending(in: dir, state: state)
        #expect(p.recordAsSwept == ["before.md"])
        #expect(p.toRead.map(\.lastPathComponent) == ["same.md"])
    }

    // F1.38: the model fails on every part: nothing is deleted, nothing is marked swept, the failure is recorded.
    @Test func modelFailingOnEveryPartLosesNothing() async throws {
        let f = try AwareSweepTests.Fixture()
        try f.addTranscript()
        f.model.extractFailures = 100
        let r = await f.run()
        #expect(r.failed)
        let state = AwareState.load(from: f.aware)
        #expect(state.swept.isEmpty)
        #expect(state.lastResult?.failed == true)
        #expect(!FileManager.default.fileExists(atPath: f.dayFile.path))
    }

    // F1.40: every finished sweep records what it read and wrote, also when it found nothing.
    @Test func sweepRecordsWhatItDid() async throws {
        let f = try AwareSweepTests.Fixture()
        try f.addTranscript()
        _ = await f.run()
        let empty = AwareState.load(from: f.aware).lastResult
        #expect(empty == AwareSweepResult(at: f.now, meetings: 1, written: 0))

        f.speak("remind me to call the vendor about it")
        f.model.items = { s in [AwareSweepTests.item(.todo, "Call the vendor", quote: "call the vendor", source: s[0].id, project: "none")] }
        let r = await f.run()
        let wrote = AwareState.load(from: f.aware).lastResult
        #expect(r.written == 1)
        #expect(wrote == AwareSweepResult(at: f.now, meetings: 1, written: 1, file: f.dayFile.path))
    }

    @Test func stateKeepsTheResultAcrossSaves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)")
        var s = AwareState()
        s.lastResult = AwareSweepResult(at: Date(timeIntervalSince1970: 1_000_000), meetings: 1, written: 3, file: "/x.md")
        try s.save(to: dir)
        #expect(AwareState.load(from: dir).lastResult == s.lastResult)
    }

    // F1.40: the page says what the last sweep did.
    @Test func pageSaysWhatTheLastSweepDid() {
        #expect(Self.page().statusLines[0] == "No sweep yet")
        #expect(Self.page(result: Self.result()).statusLines[0] == "Last sweep 12:00: nothing new to read")
        #expect(Self.page(result: Self.result(meetings: 2)).statusLines[0] == "Last sweep 12:00: read 2 meetings, nothing to propose")
        #expect(Self.page(result: Self.result(meetings: 1, written: 2)).statusLines[0] == "Last sweep 12:00: read 1 meeting, wrote 2 proposals")
        #expect(Self.page(result: Self.result(meetings: 1, failed: true)).statusLines[0] == "Last sweep 12:00 could not read. Nothing was lost, it tries again soon.")
    }

    @Test func pageSaysWhenItIsReading() {
        let reading = Self.page(sweeping: true)
        #expect(reading.statusLines[0] == "Reading now")
        #expect(!reading.sweepEnabled)
        #expect(reading.sweepTitle == "Reading")
        #expect(Self.page().sweepEnabled && Self.page().sweepTitle == "Sweep now")
        #expect(Self.page().sweepDetail == "Read waiting meetings now.")
    }

    // F1.42: the page counts only meetings still to be read; old ones recorded as swept count for the scheduler alone.
    @Test func pageCountsOnlyTranscriptsToRead() {
        let p = TranscriptSource.Pending(toRead: [URL(fileURLWithPath: "/t/a.md")], recordAsSwept: ["old1.md", "old2.md"])
        #expect(p.forScheduler == 3 && p.forPage == 1)
        let onlyOld = TranscriptSource.Pending(toRead: [], recordAsSwept: ["old1.md"])
        #expect(onlyOld.forScheduler == 1 && onlyOld.forPage == 0)
        #expect(!Self.page(pending: onlyOld.forPage).statusLines.contains { $0.contains("waiting") && $0.contains("meeting") })
    }

    // F1.42: the status lines in order: last result (or Reading now), meetings waiting when any, items waiting. No "Next around".
    @Test func statusLinesAreInOrder() {
        #expect(Self.page().statusLines == ["No sweep yet", "Nothing waiting"])
        #expect(Self.page(pending: 1).statusLines == ["No sweep yet", "1 meeting waiting", "Nothing waiting"])
        #expect(Self.page(result: Self.result(meetings: 1, written: 2), pending: 2, itemsToday: 4).statusLines
                == ["Last sweep 12:00: read 1 meeting, wrote 2 proposals", "2 meetings waiting", "4 items waiting"])
        #expect(Self.page(pending: 1, itemsToday: 1, sweeping: true).statusLines == ["Reading now", "1 meeting waiting", "1 item waiting"])
    }

    // F1.41: the app hears when a sweep ends and whether the user asked for it.
    @Test func schedulerReportsTheEndOfASweep() async {
        let e = SchedulerEnv()
        var ended: [Bool] = []
        e.scheduler.onFinished = { ended.append($0) }
        e.scheduler.sweepNow()
        await e.settle()
        #expect(ended == [true])
        e.scheduler.tick()
        await e.settle()
        #expect(ended == [true, false])
    }

    // F3.16: Sweep now tells the caller when it cannot run, so a click is never silently dropped.
    @Test func sweepNowSaysWhenItCannotRun() async {
        let e = SchedulerEnv()
        e.brain = false
        #expect(e.scheduler.sweepNow() == false)
        e.brain = true
        e.model = false
        #expect(e.scheduler.sweepNow() == false)
        e.model = true
        #expect(e.scheduler.sweepNow() == true)
        await e.settle()
    }
}
