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
