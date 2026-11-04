import Foundation
import Testing
@testable import IonianFlow

// Unit D. Model-free checks (serial ordering, no overlap). The heavy hub test (--enginetest-hub) stays a dev flag.

extension IonianFlowTests {
@Suite struct ModelHubChecks {
    /// Cheap, no model loads: the serial gate is FIFO and never runs two jobs at once.
    @Test func serialGate() {
        final class State: @unchecked Sendable {
            let lock = NSLock(); var order: [Int] = []; var running = 0; var overlap = false
        }
        let hub = ModelHub()
        let st = State()
        let done = DispatchSemaphore(value: 0)
        Task {
            // Job 0 holds the gate; jobs 1..<8 queue behind it in submission order.
            let first = Task { await hub.serial { () -> Void in
                try? await Task.sleep(nanoseconds: 100_000_000)
                st.lock.withLock { st.order.append(0) }
            } }
            try? await Task.sleep(nanoseconds: 20_000_000)
            var tasks: [Task<Void, Never>] = []
            for i in 1..<8 {
                tasks.append(Task { await hub.serial { () -> Void in
                    st.lock.withLock { st.running += 1; if st.running > 1 { st.overlap = true }; st.order.append(i) }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    st.lock.withLock { st.running -= 1 }
                } })
                try? await Task.sleep(nanoseconds: 5_000_000)  // fixes submission order
            }
            await first.value
            for t in tasks { await t.value }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success, "serial gate finished")
        #expect(st.order == Array(0..<8) && !st.overlap && hub.footprintMB() > 0, "serial gate is FIFO, no overlap")
    }

    @Test func priority() {
        final class Order: @unchecked Sendable { let lock = NSLock(); var v: [String] = [] }
        let hub = ModelHub(), o = Order(), done = DispatchSemaphore(value: 0)
        Task {
            let holder = Task { await hub.serial { try? await Task.sleep(nanoseconds: 80_000_000) } }
            try? await Task.sleep(nanoseconds: 20_000_000)
            var jobs: [Task<Void, Never>] = []
            for (name, p) in [("low1", LanePriority.low), ("low2", .low), ("high1", .high), ("high2", .high)] {
                jobs.append(Task { await hub.serial(p) { o.lock.withLock { o.v.append(name) } } })
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await holder.value
            for j in jobs { await j.value }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success && o.v == ["high1", "high2", "low1", "low2"], "high jobs first, FIFO within a priority")
    }
}
}
