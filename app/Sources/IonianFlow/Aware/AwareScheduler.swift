import Foundation

enum AwareSweepRequest: Equatable, Sendable { case scheduled, meeting(URL) }
enum AwareSweepOutcome: Equatable, Sendable { case done(capReached: Bool), failed }

protocol AwareSweeping: Sendable {
    func run(_ request: AwareSweepRequest, gate: AwareGate) async -> AwareSweepOutcome
}

/// F1.11: the sweep calls `checkpoint()` at every step; while the scheduler holds the gate it suspends.
/// A thin wrapper on `SweepControl`, which `GemmaVaultLLM(hub:control:)` checks per generated token.
final class AwareGate: @unchecked Sendable {
    let control = SweepControl()

    func hold() { control.pause() }
    func release() { control.resume() }
    func checkpoint() async { await control.waitWhilePaused() }
}

/// Decides when a sweep runs; never sweeps itself. The app calls `tick()` every 10 minutes.
@MainActor
final class AwareScheduler {
    private let sweeper: AwareSweeping
    private let gate: AwareGate
    private let clock: () -> Date
    private let isBusy: () -> Bool
    private let power: () -> AwarePower
    private let brainReady: () -> Bool
    private let modelReady: () -> Bool
    private let intervalHours: () -> Int
    private let pausedUntil: () -> Date?
    private let loadState: () -> AwareState
    private let saveState: (AwareState) -> Void
    private let meetingsOn: () -> Bool

    private(set) var running: Task<Void, Never>?
    /// A sweep ended; true when the user asked for it (F1.41).
    var onFinished: ((Bool) -> Void)?

    init(sweeper: AwareSweeping, gate: AwareGate,
         clock: @escaping () -> Date = Date.init,
         isBusy: @escaping () -> Bool,
         power: @escaping () -> AwarePower = AwarePower.current,
         brainReady: @escaping () -> Bool, modelReady: @escaping () -> Bool,
         intervalHours: @escaping () -> Int, pausedUntil: @escaping () -> Date?,
         loadState: @escaping () -> AwareState, saveState: @escaping (AwareState) -> Void, meetingsOn: @escaping () -> Bool = { true }) {
        self.sweeper = sweeper; self.gate = gate; self.clock = clock; self.isBusy = isBusy
        self.power = power; self.brainReady = brainReady; self.modelReady = modelReady
        self.intervalHours = intervalHours; self.pausedUntil = pausedUntil
        self.loadState = loadState; self.saveState = saveState; self.meetingsOn = meetingsOn
    }

    private var capDay: Date?

    /// The menu line; nil when nothing is wrong (F1.28, F1.31).
    var status: String? {
        if !brainReady() { return "Aware: no brain connected" }
        if !modelReady() { return "Aware: model not downloaded" }
        if let d = capDay, d == Calendar.current.startOfDay(for: clock()) { return "Aware: daily cap reached" }
        return nil
    }

    private var isPaused: Bool { pausedUntil().map { $0 > clock() } ?? false }
    private var lowPower: Bool { let p = power(); return p.onBattery && p.percent < 30 }

    func launch() { tick() }

    private struct Item { var request: AwareSweepRequest; var forced: Bool }
    private var queue: [Item] = []

    /// Hotkey pressed or transcription started: the sweep yields the model at once (F1.11).
    func busyStarted() { gate.hold() }

    func busyEnded() {
        gate.release()
        pump()
    }

    /// Called after the transcript is written and its summary finished or failed (F1.36).
    func meetingEnded(_ file: URL) {
        guard meetingsOn() else { return }  // F3.6
        enqueue(.meeting(file), forced: false)
    }

    /// False when it cannot run now (pause, brain, model), so the caller can say so (F3.16).
    @discardableResult
    func sweepNow() -> Bool {
        guard canRun(forced: true) else { return false }
        enqueue(.scheduled, forced: true)
        return true
    }

    func tick() {
        guard !isBusy(), !isPaused, brainReady(), modelReady(), !lowPower, isDue() else { return }
        enqueue(.scheduled, forced: false)
    }

    private func enqueue(_ request: AwareSweepRequest, forced: Bool) {
        // A meeting that cannot run now because of pause, brain, model or battery is left for the next scheduled sweep (F1.36).
        if case .meeting = request, !canRun(forced: false) { return }
        if queue.contains(where: { $0.request == request }) { return }
        queue.append(Item(request: request, forced: forced))
        pump()
    }

    private func canRun(forced: Bool) -> Bool {
        !isPaused && brainReady() && modelReady() && (forced || !lowPower)
    }

    /// Starts the next queued request when nothing runs and Flow is idle.
    private func pump() {
        guard running == nil, !isBusy() else { return }
        while !queue.isEmpty {
            let item = queue.removeFirst()
            guard canRun(forced: item.forced) else { continue }  // dropped; a scheduled one stays due
            start(item)
            return
        }
    }

    private func isDue() -> Bool {
        guard let last = loadState().lastSweep else { return true }
        return clock().timeIntervalSince(last) >= Double(max(intervalHours(), 1)) * 3600
    }

    private func start(_ item: Item) {
        let sweeper = self.sweeper, gate = self.gate
        running = Task(priority: .background) { [weak self] in
            let outcome = await sweeper.run(item.request, gate: gate)
            self?.finished(item, outcome)
        }
    }

    private func finished(_ item: Item, _ outcome: AwareSweepOutcome) {
        let request = item.request
        running = nil
        if case .done(capReached: true) = outcome { capDay = Calendar.current.startOfDay(for: clock()) }
        if request == .scheduled, case .done = outcome {
            var s = loadState()
            s.lastSweep = clock()
            saveState(s)
        }
        onFinished?(item.forced)
        pump()
    }
}
