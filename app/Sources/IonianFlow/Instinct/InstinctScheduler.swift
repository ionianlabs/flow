import Foundation

enum InstinctSweepRequest: Equatable, Sendable { case scheduled, meeting(URL) }
enum InstinctSweepOutcome: Equatable, Sendable { case done(capReached: Bool), failed }

protocol InstinctSweeping: Sendable {
    func run(_ request: InstinctSweepRequest, gate: InstinctGate) async -> InstinctSweepOutcome
}

/// F1.11: the sweep calls `checkpoint()` at every step and the model per token; while the scheduler holds the gate it suspends.
final class InstinctGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func hold() {
        lock.lock(); held = true; lock.unlock()
    }

    func release() {
        lock.lock()
        held = false
        let w = waiting
        waiting = []
        lock.unlock()
        w.forEach { $0.resume() }
    }

    func checkpoint() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held { waiting.append(c); lock.unlock() } else { lock.unlock(); c.resume() }
        }
    }
}

/// Decides when a sweep runs; never sweeps itself. The app calls `tick()` every 10 minutes.
@MainActor
final class InstinctScheduler {
    private let sweeper: InstinctSweeping
    private let gate: InstinctGate
    private let clock: () -> Date
    private let isBusy: () -> Bool
    private let power: () -> InstinctPower
    private let brainReady: () -> Bool
    private let modelReady: () -> Bool
    private let intervalHours: () -> Int
    private let pausedUntil: () -> Date?
    private let loadState: () -> InstinctState
    private let saveState: (InstinctState) -> Void

    private(set) var running: Task<Void, Never>?

    init(sweeper: InstinctSweeping, gate: InstinctGate,
         clock: @escaping () -> Date = Date.init,
         isBusy: @escaping () -> Bool,
         power: @escaping () -> InstinctPower = InstinctPower.current,
         brainReady: @escaping () -> Bool, modelReady: @escaping () -> Bool,
         intervalHours: @escaping () -> Int, pausedUntil: @escaping () -> Date?,
         loadState: @escaping () -> InstinctState, saveState: @escaping (InstinctState) -> Void) {
        self.sweeper = sweeper; self.gate = gate; self.clock = clock; self.isBusy = isBusy
        self.power = power; self.brainReady = brainReady; self.modelReady = modelReady
        self.intervalHours = intervalHours; self.pausedUntil = pausedUntil
        self.loadState = loadState; self.saveState = saveState
    }

    private var capDay: Date?

    /// The menu line; nil when nothing is wrong (F1.28, F1.31).
    var status: String? {
        if !brainReady() { return "Instinct: no brain connected" }
        if !modelReady() { return "Instinct: model not downloaded" }
        if let d = capDay, d == Calendar.current.startOfDay(for: clock()) { return "Instinct: daily cap reached" }
        return nil
    }

    private var isPaused: Bool { pausedUntil().map { $0 > clock() } ?? false }
    private var lowPower: Bool { let p = power(); return p.onBattery && p.percent < 30 }

    func launch() { tick() }

    func tick() {
        guard !isBusy(), !isPaused, brainReady(), modelReady(), !lowPower, isDue() else { return }
        start(.scheduled)
    }

    private func isDue() -> Bool {
        guard let last = loadState().lastSweep else { return true }
        return clock().timeIntervalSince(last) >= Double(max(intervalHours(), 1)) * 3600
    }

    private func start(_ request: InstinctSweepRequest) {
        guard running == nil else { return }
        let sweeper = self.sweeper, gate = self.gate
        running = Task(priority: .background) { [weak self] in
            let outcome = await sweeper.run(request, gate: gate)
            self?.finished(request, outcome)
        }
    }

    private func finished(_ request: InstinctSweepRequest, _ outcome: InstinctSweepOutcome) {
        running = nil
        if case .done(capReached: true) = outcome { capDay = Calendar.current.startOfDay(for: clock()) }
        if request == .scheduled, case .done = outcome {
            var s = loadState()
            s.lastSweep = clock()
            saveState(s)
        }
    }
}
