import Foundation
import Testing
@testable import IonianFlow

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

@Suite struct AwareGateTests {
    @Test func checkpointReturnsAtOnceWhenNotHeld() async {
        let gate = AwareGate()
        await gate.checkpoint()
    }

    @Test func heldGateSuspendsCheckpointUntilRelease() async throws {
        let gate = AwareGate()
        let passed = Flag()
        gate.hold()
        let t = Task { await gate.checkpoint(); passed.set() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!passed.value)
        gate.release()
        await t.value
        #expect(passed.value)
    }

    @Test func holdReturnsImmediatelyAndReleaseWithoutHoldIsHarmless() {
        let gate = AwareGate()
        gate.release()
        gate.hold()
        gate.hold()
        gate.release()
    }
}

// MARK: - Scheduler

final class FakeSweeper: AwareSweeping, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [AwareSweepRequest] = []
    private var pending: CheckedContinuation<AwareSweepOutcome, Never>?
    var outcome: AwareSweepOutcome = .done(capReached: false)
    /// When true a run suspends until `finish` is called.
    var blocking = false
    var runs: [AwareSweepRequest] { lock.lock(); defer { lock.unlock() }; return _runs }

    private func record(_ r: AwareSweepRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _runs.append(r)
        return blocking
    }

    func run(_ request: AwareSweepRequest, gate: AwareGate) async -> AwareSweepOutcome {
        let block = record(request)
        if !block { return outcome }
        return await withCheckedContinuation { c in lock.lock(); pending = c; lock.unlock() }
    }

    func finish(_ o: AwareSweepOutcome = .done(capReached: false)) {
        lock.lock(); let c = pending; pending = nil; lock.unlock()
        c?.resume(returning: o)
    }
}

@MainActor
final class SchedulerEnv {
    var now = SchedulerEnv.date(2026, 11, 5, 12, 0)
    var busy = false
    var power = AwarePower(onBattery: false, percent: 100)
    var brain = true
    var model = true
    /// Transcripts waiting (F1.42).
    var pending = 1
    let sweeper = FakeSweeper()
    let gate = AwareGate()
    lazy var scheduler = AwareScheduler(
        sweeper: sweeper, gate: gate,
        clock: { [unowned self] in MainActor.assumeIsolated { self.now } },
        isBusy: { [unowned self] in MainActor.assumeIsolated { self.busy } },
        power: { [unowned self] in MainActor.assumeIsolated { self.power } },
        brainReady: { [unowned self] in MainActor.assumeIsolated { self.brain } },
        modelReady: { [unowned self] in MainActor.assumeIsolated { self.model } },
        pendingMeetings: { [unowned self] in MainActor.assumeIsolated { self.pending } })

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Waits for the running sweep task to end.
    func settle() async { await scheduler.running?.value }
    func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

@MainActor @Suite struct AwareSchedulerTests {
    // F1.42
    @Test func catchUpRunsWhenSomethingIsPendingAndFlowIsIdle() async {
        let e = SchedulerEnv()
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    @Test func launchRunsCatchUpForMeetingsLeftFromBefore() async {
        let e = SchedulerEnv()
        e.scheduler.launch()
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    @Test func noCatchUpWhenNothingIsPending() async {
        let e = SchedulerEnv()
        e.pending = 0
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [])
    }

    @Test func noCatchUpWhileBusy() async {
        let e = SchedulerEnv()
        e.busy = true
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [])
    }

    @Test func noCatchUpWhileASweepRuns() async {
        let e = SchedulerEnv()
        e.sweeper.blocking = true
        e.scheduler.tick()
        await e.waitUntil { e.sweeper.runs.count == 1 }
        e.scheduler.tick()
        e.scheduler.tick()
        #expect(e.sweeper.runs == [.catchUp])
        e.sweeper.blocking = false
        e.sweeper.finish()
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    // F1.10
    @Test func batteryBelowThirtySkipsCatchUpAndLaterCheckRunsIt() async {
        let e = SchedulerEnv()
        e.power = AwarePower(onBattery: true, percent: 29)
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [])
        e.power = AwarePower(onBattery: true, percent: 30)
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    @Test func chargerConnectedRunsCatchUpAtLowPercent() async {
        let e = SchedulerEnv()
        e.power = AwarePower(onBattery: false, percent: 10)
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    // F1.31
    @Test func noBrainOrNoModelBlocksSweepAndSetsStatus() async {
        let e = SchedulerEnv()
        #expect(e.scheduler.status == nil)
        e.brain = false
        e.model = false
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [])
        #expect(e.scheduler.status == "Aware: no brain connected")
        e.brain = true
        #expect(e.scheduler.status == "Aware: model not downloaded")
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [])
        e.model = true
        #expect(e.scheduler.status == nil)
    }

    // F1.28
    @Test func capReachedStatusUntilMidnightAndCatchUpsStillRun() async {
        let e = SchedulerEnv()
        e.sweeper.outcome = .done(capReached: true)
        e.scheduler.tick()
        await e.settle()
        #expect(e.scheduler.status == "Aware: daily cap reached")
        e.now = SchedulerEnv.date(2026, 11, 5, 23, 59)
        #expect(e.scheduler.status == "Aware: daily cap reached")
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs.count == 2)
        e.now = SchedulerEnv.date(2026, 11, 6, 0, 0)
        #expect(e.scheduler.status == nil)
    }

    private let m1 = URL(fileURLWithPath: "/tmp/fixture-a.md")
    private let m2 = URL(fileURLWithPath: "/tmp/fixture-b.md")

    // F1.11
    @Test func busyHoldsGateAtOnceAndBusyEndedReleasesIt() async {
        let e = SchedulerEnv()
        let passed = Flag()
        e.scheduler.busyStarted()
        e.busy = true
        let t = Task.detached { [gate = e.gate] in await gate.checkpoint(); passed.set() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!passed.value)
        e.busy = false
        e.scheduler.busyEnded()
        await t.value
        #expect(passed.value)
    }

    // F1.36
    @Test func meetingEndedWhenIdleStartsAtOnce() async {
        let e = SchedulerEnv()
        e.scheduler.meetingEnded(m1)
        await e.settle()
        #expect(e.sweeper.runs == [.meeting(m1)])
    }

    @Test func meetingEndedWhileBusyStartsWhenBusyEnds() async {
        let e = SchedulerEnv()
        e.busy = true
        e.scheduler.busyStarted()
        e.scheduler.meetingEnded(m1)
        await e.settle()
        #expect(e.sweeper.runs == [])
        e.busy = false
        e.scheduler.busyEnded()
        await e.settle()
        #expect(e.sweeper.runs == [.meeting(m1)])
    }

    // F1.36 with F1.10, F1.42: the meeting that could not run at its end is read by the next tick
    @Test func meetingOnLowBatteryIsDroppedAndTheNextTickReadsIt() async {
        let e = SchedulerEnv()
        e.power = AwarePower(onBattery: true, percent: 20)
        e.scheduler.meetingEnded(m1)
        await e.settle()
        #expect(e.sweeper.runs == [])
        e.power = AwarePower(onBattery: false, percent: 100)
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    @Test func meetingWithoutBrainOrModelIsDroppedAndTheNextTickReadsIt() async {
        let e = SchedulerEnv()
        e.brain = false
        e.scheduler.meetingEnded(m1)
        e.brain = true
        e.model = false
        e.scheduler.meetingEnded(m2)
        e.model = true
        e.scheduler.busyEnded()
        await e.settle()
        #expect(e.sweeper.runs == [])
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    @Test func meetingThatFailedIsReadByTheNextTick() async {
        let e = SchedulerEnv()
        e.sweeper.outcome = .failed
        e.scheduler.meetingEnded(m1)
        await e.settle()
        #expect(e.sweeper.runs == [.meeting(m1)])
        e.sweeper.outcome = .done(capReached: false)
        e.scheduler.tick()
        await e.settle()
        #expect(e.sweeper.runs == [.meeting(m1), .catchUp])
    }

    // F1.37
    @Test func meetingDuringCatchUpQueuesInOrderWithoutDuplicates() async {
        let e = SchedulerEnv()
        e.sweeper.blocking = true
        e.scheduler.tick()
        await e.waitUntil { e.sweeper.runs.count == 1 }
        e.scheduler.meetingEnded(m1)
        e.scheduler.meetingEnded(m2)
        e.scheduler.meetingEnded(m1)
        #expect(e.sweeper.runs == [.catchUp])
        e.sweeper.finish()
        await e.waitUntil { e.sweeper.runs.count == 2 }
        #expect(e.sweeper.runs == [.catchUp, .meeting(m1)])
        e.sweeper.finish()
        await e.waitUntil { e.sweeper.runs.count == 3 }
        #expect(e.sweeper.runs == [.catchUp, .meeting(m1), .meeting(m2)])
        e.sweeper.blocking = false
        e.sweeper.finish()
        await e.settle()
        #expect(e.sweeper.runs.count == 3)
    }

    // Interfaces: Sweep now
    @Test func sweepNowRunsACatchUpEvenOnLowBatteryAndWithNothingPending() async {
        let e = SchedulerEnv()
        e.pending = 0
        e.power = AwarePower(onBattery: true, percent: 5)
        #expect(e.scheduler.sweepNow())
        await e.settle()
        #expect(e.sweeper.runs == [.catchUp])
    }

    @Test func sweepNowHonoursBrainModelAndBusy() async {
        let e = SchedulerEnv()
        e.brain = false
        #expect(!e.scheduler.sweepNow())
        e.brain = true
        e.model = false
        #expect(!e.scheduler.sweepNow())
        e.model = true
        e.busy = true
        e.scheduler.sweepNow()
        await e.settle()
        #expect(e.sweeper.runs == [])
    }
}
