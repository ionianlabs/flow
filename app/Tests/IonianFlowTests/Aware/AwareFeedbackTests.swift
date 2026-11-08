import Foundation
import Testing
@testable import IonianFlow

// Spec F1.38 to F1.41, F3.16: a sweep says what it did, a model that cannot read loses nothing, a pause can be undone.
@MainActor @Suite struct AwareFeedbackTests {
    static func at(_ s: String) -> Date { TranscriptSourceTests.local(s) }
    static let brain = URL(fileURLWithPath: "/Users/sample/Ionian/brain", isDirectory: true)
    static let noon = at("2026-11-06 12:00")

    static func page(paused: Date? = nil, result: AwareSweepResult? = nil, collected: Int = 0, sweeping: Bool = false) -> AwarePageState {
        var state = AwareState(enabledAt: nil, swept: [], lastSweep: noon)
        state.lastResult = result
        return AwarePageState.make(settings: AwarePageSettings(on: true, intervalHours: 3, pausedUntil: paused), brain: brain,
                                      cleanupInstalled: true, state: state, now: at("2026-11-06 13:10"), itemsToday: 0,
                                      collected: collected, sweeping: sweeping, home: "/h")
    }

    static func result(meetings: Int = 0, dictations: Int = 0, written: Int = 0, failed: Bool = false) -> AwareSweepResult {
        AwareSweepResult(at: noon, meetings: meetings, dictations: dictations, written: written, failed: failed)
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
        f.dictate("remind me to renew the vendor contract")
        f.model.extractFailures = 100
        let r = await f.run()
        #expect(r.failed)
        #expect(f.buffer.read().count == 1)
        let state = AwareState.load(from: f.aware)
        #expect(state.swept.isEmpty)
        #expect(state.lastResult?.failed == true)
        #expect(!FileManager.default.fileExists(atPath: f.dayFile.path))
    }

    // F1.40: every finished sweep records what it read and wrote, also when it found nothing.
    @Test func sweepRecordsWhatItDid() async throws {
        let f = try AwareSweepTests.Fixture()
        try f.addTranscript()
        f.dictate("remind me to renew the vendor contract")
        _ = await f.run()
        let empty = AwareState.load(from: f.aware).lastResult
        #expect(empty == AwareSweepResult(at: f.now, meetings: 1, dictations: 1, written: 0))

        f.dictate("remind me to call the vendor about it")
        f.model.items = { s in [AwareSweepTests.item(.todo, "Call the vendor", quote: "call the vendor", source: s[0].id, project: "none")] }
        let r = await f.run()
        let wrote = AwareState.load(from: f.aware).lastResult
        #expect(r.written == 1)
        #expect(wrote == AwareSweepResult(at: f.now, meetings: 0, dictations: 1, written: 1, file: f.dayFile.path))
    }

    @Test func stateKeepsTheResultAcrossSaves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)")
        var s = AwareState()
        s.lastResult = AwareSweepResult(at: Date(timeIntervalSince1970: 1_000_000), meetings: 1, dictations: 2, written: 3, file: "/x.md")
        try s.save(to: dir)
        #expect(AwareState.load(from: dir).lastResult == s.lastResult)
    }

    // F1.40: the page says what the last sweep did.
    @Test func pageSaysWhatTheLastSweepDid() {
        #expect(Self.page().statusLines[0] == "Last sweep 12:00")
        #expect(Self.page(result: Self.result()).statusLines[0] == "Last sweep 12:00: nothing new to read")
        #expect(Self.page(result: Self.result(meetings: 1, dictations: 3)).statusLines[0]
                == "Last sweep 12:00: read 1 meeting and 3 dictations, nothing to propose")
        #expect(Self.page(result: Self.result(dictations: 1, written: 2)).statusLines[0] == "Last sweep 12:00: read 1 dictation, wrote 2 proposals")
        #expect(Self.page(result: Self.result(dictations: 1, failed: true)).statusLines[0] == "Last sweep 12:00 could not read. Nothing was lost, it tries again soon.")
    }

    @Test func pageSaysWhenItIsReadingAndWhatIsCollected() {
        let reading = Self.page(sweeping: true)
        #expect(reading.statusLines[0] == "Reading now")
        #expect(!reading.sweepEnabled)
        #expect(reading.sweepTitle == "Reading")
        #expect(Self.page(collected: 3).statusLines.last == "3 dictations collected")
        #expect(Self.page(collected: 1).statusLines.last == "1 dictation collected")
        #expect(Self.page().sweepEnabled && Self.page().sweepTitle == "Sweep now")
    }

    // F3.16: while paused, Sweep now is off and says why, and the pause can be undone.
    @Test func pauseExplainsItselfAndCanBeUndone() {
        let s = Self.page(paused: Self.at("2026-11-06 14:05"))
        #expect(!s.sweepEnabled)
        #expect(s.sweepDetail == "Paused until 14:05. Resume to read now.")
        #expect(s.isPaused)
        #expect(!Self.page().isPaused)
        #expect(Self.page().sweepDetail == AwarePage.sweepDetail)

        let until = Self.at("2026-11-06 14:05")
        let now = Self.at("2026-11-06 13:10")
        let m = AwareApp.menuLines(status: nil, pausedUntil: until, now: now)
        #expect(m.status == "Aware: paused until 14:05")
        #expect(m.actions == [AwareApp.resumeTitle])
        #expect(AwareApp.menuLines(status: nil, pausedUntil: nil, now: now).actions == [AwareApp.sweepNowTitle, AwareApp.pauseTitle])
    }

    // F1.41: proposals always notify; "nothing" only answers a sweep the user asked for.
    @Test func noticeCopy() {
        #expect(AwareApp.notice(Self.result(dictations: 2), manual: false) == nil)
        #expect(AwareApp.notice(Self.result(dictations: 1, failed: true), manual: false) == nil)
        let two = AwareApp.notice(Self.result(meetings: 1, dictations: 2, written: 2), manual: false)
        #expect(two?.title == "Aware wrote 2 proposals to your inbox.")
        #expect(two?.body == "From 1 meeting and 2 dictations. Open to review.")
        #expect(AwareApp.notice(Self.result(written: 1), manual: false)?.title == "Aware wrote 1 proposal to your inbox.")
        #expect(AwareApp.notice(Self.result(), manual: true)?.title == "Nothing new for Aware to read.")
        #expect(AwareApp.notice(Self.result(dictations: 2), manual: true)?.title == "Aware found nothing to propose.")
        #expect(AwareApp.notice(Self.result(dictations: 2), manual: true)?.body == "It read 2 dictations.")
        #expect(AwareApp.notice(Self.result(dictations: 2, failed: true), manual: true)?.title == "Aware could not read this time.")
    }

    // F1.41: the app hears when a sweep ends and whether the user asked for it.
    @Test func schedulerReportsTheEndOfASweep() async {
        let e = SchedulerEnv()
        var ended: [Bool] = []
        e.scheduler.onFinished = { ended.append($0) }
        e.scheduler.sweepNow()
        await e.settle()
        #expect(ended == [true])
        e.now = SchedulerEnv.date(2026, 11, 6, 12, 0)
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
        e.pausedUntil = SchedulerEnv.date(2026, 11, 5, 13, 0)
        #expect(e.scheduler.sweepNow() == false)
        e.pausedUntil = nil
        #expect(e.scheduler.sweepNow() == true)
        await e.settle()
    }
}
