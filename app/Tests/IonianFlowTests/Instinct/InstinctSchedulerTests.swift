import XCTest
@testable import IonianFlow

final class InstinctGateTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
        func set() { lock.lock(); v = true; lock.unlock() }
    }

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
