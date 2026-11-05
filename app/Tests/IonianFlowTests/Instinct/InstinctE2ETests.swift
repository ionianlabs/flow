import Foundation
import Testing
@testable import IonianFlow

// End to end with real Gemma: the real sweep (sources, chunks, extract, guards, gate, dedup, caps, writer) on invented
// fixtures with labelled planted items. Prints exactly what would be written and the precision and recall.
//   IONIAN_FLOW_METALLIB=... IONIAN_FLOW_MODEL_TESTS=1 swift test --package-path app --filter InstinctE2E
// The held-out meeting runs only with IONIAN_FLOW_HELDOUT=1 (once, at the end of the tuning).

private typealias F = InstinctGemmaFixtures
private let heldOutEnabled = ProcessInfo.processInfo.environment["IONIAN_FLOW_HELDOUT"] == "1"

extension IonianFlowTests {
@Suite(.serialized) struct InstinctE2ETests {
    let model = GemmaInstinctModel(llm: GemmaVaultLLM(hub: .shared, control: nil))

    private func warmUp() async {
        _ = try? await model.judge(InstinctItem(category: .todo, text: "warm up", owner: nil, due: nil, quote: "q", sourceID: "s", project: "none", confidence: 0.9, conflicts: nil), against: ["x"])
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func meeting60() async throws {
        await warmUp()
        let s = try await InstinctE2E.meeting(title: "60-minute meeting", sources: F.meeting(file: "m1.md", minutes: 60, seed: 1, plants: F.meeting1Plants), labels: F.meeting1Labels, model: model)
        s.print()
        #expect(s.seconds < 300, "SC8")
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func meeting15() async throws {
        await warmUp()
        let s = try await InstinctE2E.meeting(title: "15-minute meeting", sources: F.meeting(file: "m2.md", minutes: 15, seed: 2, plants: F.meeting2Plants), labels: F.meeting2Labels, model: model)
        s.print()
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func dictations20() async throws {
        await warmUp()
        let s = try await InstinctE2E.dictations(model: model)
        s.print()
    }

    @Test(.enabled(if: modelTestsEnabled && heldOutEnabled, "held-out: needs IONIAN_FLOW_MODEL_TESTS=1 and IONIAN_FLOW_HELDOUT=1")) func heldOutMeeting() async throws {
        await warmUp()
        let s = try await InstinctE2E.meeting(title: "held-out 30-minute meeting", sources: InstinctHeldOutFixture.meeting(file: "h.md"), labels: InstinctHeldOutFixture.labels, model: model,
                                              projects: InstinctHeldOutFixture.projects)
        s.print()
    }
}
}
