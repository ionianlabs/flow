import XCTest
@testable import IonianFlow

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

final class InstinctGateTests: XCTestCase {
    func testCheckpointReturnsAtOnceWhenNotHeld() async {
        let gate = InstinctGate()
        await gate.checkpoint()
    }

    func testHeldGateSuspendsCheckpointUntilRelease() async throws {
        let gate = InstinctGate()
        let passed = Flag()
        gate.hold()
        let t = Task { await gate.checkpoint(); passed.set() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(passed.value)
        gate.release()
        await t.value
        XCTAssertTrue(passed.value)
    }

    func testHoldReturnsImmediatelyAndReleaseWithoutHoldIsHarmless() {
        let gate = InstinctGate()
        gate.release()
        gate.hold()
        gate.hold()
        gate.release()
    }
}

// MARK: - Scheduler

final class FakeSweeper: InstinctSweeping, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [InstinctSweepRequest] = []
    private var pending: CheckedContinuation<InstinctSweepOutcome, Never>?
    var outcome: InstinctSweepOutcome = .done(capReached: false)
    /// When true a run suspends until `finish` is called.
    var blocking = false
    var runs: [InstinctSweepRequest] { lock.lock(); defer { lock.unlock() }; return _runs }

    func run(_ request: InstinctSweepRequest, gate: InstinctGate) async -> InstinctSweepOutcome {
        lock.lock(); _runs.append(request); let block = blocking; lock.unlock()
        if !block { return outcome }
        return await withCheckedContinuation { c in lock.lock(); pending = c; lock.unlock() }
    }

    func finish(_ o: InstinctSweepOutcome = .done(capReached: false)) {
        lock.lock(); let c = pending; pending = nil; lock.unlock()
        c?.resume(returning: o)
    }
}

@MainActor
final class SchedulerEnv {
    var now = SchedulerEnv.date(2026, 11, 5, 12, 0)
    var busy = false
    var power = InstinctPower(onBattery: false, percent: 100)
    var brain = true
    var model = true
    var hours = 3
    var pausedUntil: Date?
    var state = InstinctState(enabledAt: SchedulerEnv.date(2026, 11, 1, 8, 0), swept: [], lastSweep: SchedulerEnv.date(2026, 11, 5, 9, 0))
    let sweeper = FakeSweeper()
    let gate = InstinctGate()
    lazy var scheduler = InstinctScheduler(
        sweeper: sweeper, gate: gate,
        clock: { [unowned self] in MainActor.assumeIsolated { self.now } },
        isBusy: { [unowned self] in MainActor.assumeIsolated { self.busy } },
        power: { [unowned self] in MainActor.assumeIsolated { self.power } },
        brainReady: { [unowned self] in MainActor.assumeIsolated { self.brain } },
        modelReady: { [unowned self] in MainActor.assumeIsolated { self.model } },
        intervalHours: { [unowned self] in MainActor.assumeIsolated { self.hours } },
        pausedUntil: { [unowned self] in MainActor.assumeIsolated { self.pausedUntil } },
        loadState: { [unowned self] in MainActor.assumeIsolated { self.state } },
        saveState: { [unowned self] s in MainActor.assumeIsolated { self.state = s } })

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Waits for the running sweep task to end.
    func settle() async { await scheduler.running?.value }
    func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

@MainActor
final class InstinctSchedulerTests: XCTestCase {
    // F1.9: lastSweep 09:00, interval 3
    func testSweepStartsAtTwelveAndNotAtElevenFiftyNine() async {
        let e = SchedulerEnv()
        e.now = SchedulerEnv.date(2026, 11, 5, 11, 59)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
        e.now = SchedulerEnv.date(2026, 11, 5, 12, 0)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
    }

    func testDoneSetsLastSweepSoMissedSweepRunsOnlyOnce() async {
        let e = SchedulerEnv()
        e.now = SchedulerEnv.date(2026, 11, 5, 20, 0) // slept for 11 hours
        e.scheduler.launch()
        await e.settle()
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
        XCTAssertEqual(e.state.lastSweep, e.now)
        XCTAssertEqual(e.state.enabledAt, SchedulerEnv.date(2026, 11, 1, 8, 0))
    }

    func testNoLastSweepIsDue() async {
        let e = SchedulerEnv()
        e.state.lastSweep = nil
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
    }

    func testFailedSweepKeepsLastSweep() async {
        let e = SchedulerEnv()
        e.sweeper.outcome = .failed
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.state.lastSweep, SchedulerEnv.date(2026, 11, 5, 9, 0))
    }

    // F1.10
    func testBatteryBelowThirtySkipsDueSweepAndLaterCheckRunsIt() async {
        let e = SchedulerEnv()
        e.power = InstinctPower(onBattery: true, percent: 29)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
        e.power = InstinctPower(onBattery: true, percent: 30)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
    }

    func testChargerConnectedRunsDueSweepAtLowPercent() async {
        let e = SchedulerEnv()
        e.power = InstinctPower(onBattery: false, percent: 10)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
    }

    // F1.4
    func testPausedUntilInTheFutureBlocksSweeps() async {
        let e = SchedulerEnv()
        e.pausedUntil = SchedulerEnv.date(2026, 11, 5, 13, 0)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
        e.now = SchedulerEnv.date(2026, 11, 5, 13, 0)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
    }

    // F1.31
    func testNoBrainOrNoModelBlocksSweepAndSetsStatus() async {
        let e = SchedulerEnv()
        XCTAssertNil(e.scheduler.status)
        e.brain = false
        e.model = false
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
        XCTAssertEqual(e.scheduler.status, "Instinct: no brain connected")
        e.brain = true
        XCTAssertEqual(e.scheduler.status, "Instinct: model not downloaded")
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
        e.model = true
        XCTAssertNil(e.scheduler.status)
    }

    // F1.28
    func testCapReachedStatusUntilMidnightAndScheduledSweepsStillRun() async {
        let e = SchedulerEnv()
        e.sweeper.outcome = .done(capReached: true)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.scheduler.status, "Instinct: daily cap reached")
        e.now = SchedulerEnv.date(2026, 11, 5, 23, 59)
        XCTAssertEqual(e.scheduler.status, "Instinct: daily cap reached")
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs.count, 2)
        e.now = SchedulerEnv.date(2026, 11, 6, 0, 0)
        XCTAssertNil(e.scheduler.status)
    }

    private let m1 = URL(fileURLWithPath: "/tmp/fixture-a.md")
    private let m2 = URL(fileURLWithPath: "/tmp/fixture-b.md")

    // F1.11
    func testBusyHoldsGateAtOnceAndBusyEndedReleasesIt() async {
        let e = SchedulerEnv()
        let passed = Flag()
        e.scheduler.busyStarted()
        e.busy = true
        let t = Task.detached { [gate = e.gate] in await gate.checkpoint(); passed.set() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(passed.value)
        e.busy = false
        e.scheduler.busyEnded()
        await t.value
        XCTAssertTrue(passed.value)
    }

    func testDueSweepDoesNotStartWhileBusy() async {
        let e = SchedulerEnv()
        e.busy = true
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
    }

    // F1.36
    func testMeetingEndedWhenIdleStartsAtOnceEvenIfScheduledNotDue() async {
        let e = SchedulerEnv()
        e.now = SchedulerEnv.date(2026, 11, 5, 10, 45)
        e.scheduler.meetingEnded(m1)
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.meeting(m1)])
        XCTAssertEqual(e.state.lastSweep, SchedulerEnv.date(2026, 11, 5, 9, 0))
    }

    func testMeetingEndedWhileBusyStartsWhenBusyEnds() async {
        let e = SchedulerEnv()
        e.busy = true
        e.scheduler.busyStarted()
        e.scheduler.meetingEnded(m1)
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
        e.busy = false
        e.scheduler.busyEnded()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.meeting(m1)])
    }

    // F1.36 with F1.10
    func testMeetingOnLowBatteryIsDroppedNotQueued() async {
        let e = SchedulerEnv()
        e.power = InstinctPower(onBattery: true, percent: 20)
        e.scheduler.meetingEnded(m1)
        await e.settle()
        e.power = InstinctPower(onBattery: false, percent: 100)
        e.now = SchedulerEnv.date(2026, 11, 5, 12, 0)
        e.scheduler.tick()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
    }

    func testMeetingIsDroppedWhilePausedOrWithoutBrain() async {
        let e = SchedulerEnv()
        e.pausedUntil = SchedulerEnv.date(2026, 11, 5, 13, 0)
        e.scheduler.meetingEnded(m1)
        e.pausedUntil = nil
        e.brain = false
        e.scheduler.meetingEnded(m2)
        e.brain = true
        e.scheduler.busyEnded()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
    }

    // F1.37
    func testMeetingDuringScheduledSweepQueuesInOrderWithoutDuplicates() async {
        let e = SchedulerEnv()
        e.sweeper.blocking = true
        e.scheduler.tick()
        await e.waitUntil { e.sweeper.runs.count == 1 }
        e.scheduler.meetingEnded(m1)
        e.scheduler.meetingEnded(m2)
        e.scheduler.meetingEnded(m1)
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
        e.sweeper.finish()
        await e.waitUntil { e.sweeper.runs.count == 2 }
        XCTAssertEqual(e.sweeper.runs, [.scheduled, .meeting(m1)])
        e.sweeper.finish()
        await e.waitUntil { e.sweeper.runs.count == 3 }
        XCTAssertEqual(e.sweeper.runs, [.scheduled, .meeting(m1), .meeting(m2)])
        e.sweeper.blocking = false
        e.sweeper.finish()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs.count, 3)
    }

    // Interfaces: Sweep now
    func testSweepNowIgnoresIntervalAndBatteryAndResetsLastSweep() async {
        let e = SchedulerEnv()
        e.now = SchedulerEnv.date(2026, 11, 5, 9, 30)
        e.power = InstinctPower(onBattery: true, percent: 5)
        e.scheduler.sweepNow()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [.scheduled])
        XCTAssertEqual(e.state.lastSweep, e.now)
    }

    func testSweepNowHonoursPauseBrainModelAndBusy() async {
        let e = SchedulerEnv()
        e.pausedUntil = SchedulerEnv.date(2026, 11, 5, 13, 0)
        e.scheduler.sweepNow()
        e.pausedUntil = nil
        e.brain = false
        e.scheduler.sweepNow()
        e.brain = true
        e.model = false
        e.scheduler.sweepNow()
        e.model = true
        e.busy = true
        e.scheduler.sweepNow()
        await e.settle()
        XCTAssertEqual(e.sweeper.runs, [])
    }
}
