import Foundation
import Testing
@testable import IonianFlow

// End to end with real Gemma: the real sweep (sources, chunks, extract, guards, gate, dedup, caps, writer) on invented
// fixtures with labelled planted items. Prints exactly what would be written and the precision and recall.
//   IONIAN_FLOW_METALLIB=... IONIAN_FLOW_MODEL_TESTS=1 swift test --package-path app --filter AwareE2E
// The held-out meeting runs only with IONIAN_FLOW_HELDOUT=1 (once, at the end of the tuning).

private typealias F = AwareGemmaFixtures
private let heldOutEnabled = ProcessInfo.processInfo.environment["IONIAN_FLOW_HELDOUT"] == "1"

/// Prints every answer of the model when IONIAN_FLOW_AWARE_DEBUG=1.
private struct DebugLLM: VaultLLM {
    let base: VaultLLM
    func chat(_ messages: [ChatMsg], maxTokens: Int) async throws -> String {
        let a = try await base.chat(messages, maxTokens: maxTokens)
        if ProcessInfo.processInfo.environment["IONIAN_FLOW_AWARE_DEBUG"] == "1" {
            print("ASK: \((messages.last?.content ?? "").suffix(maxTokens > 100 ? 0 : 300).replacingOccurrences(of: "\n", with: " | "))\nRAW: \(a)")
        }
        return a
    }
}

extension IonianFlowTests {
@Suite(.serialized) struct AwareE2ETests {
    let model = GemmaAwareModel(llm: DebugLLM(base: GemmaVaultLLM(hub: .shared, control: nil)))

    private func warmUp() async {
        _ = try? await model.judge(AwareItem(category: .todo, text: "warm up", owner: nil, due: nil, quote: "q", sourceID: "s", project: "none", confidence: 0.9, conflicts: nil), against: ["x"])
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func meeting60() async throws {
        await warmUp()
        let s = try await AwareE2E.meeting(title: "60-minute meeting", sources: F.meeting(file: "m1.md", minutes: 60, seed: 1, plants: F.meeting1Plants), labels: F.meeting1Labels, model: model)
        s.print()
        #expect(s.seconds < 300, "SC8")
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func meeting15() async throws {
        await warmUp()
        let s = try await AwareE2E.meeting(title: "15-minute meeting", sources: F.meeting(file: "m2.md", minutes: 15, seed: 2, plants: F.meeting2Plants), labels: F.meeting2Labels, model: model)
        s.print()
    }

    // SC7 through the real sweep: 3 hours of meetings in one catch-up, under 10 minutes.
    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func sc7SweepThreeHoursOfMeetings() async throws {
        await warmUp()
        let t0 = Date()
        var written = 0
        let sets = [F.meeting(file: "a.md", minutes: 60, seed: 1, plants: F.meeting1Plants), F.meeting(file: "b.md", minutes: 15, seed: 2, plants: F.meeting2Plants),
                    F.meeting(file: "c.md", minutes: 60, seed: 3, plants: F.meeting1Plants), F.meeting(file: "d.md", minutes: 45, seed: 4, plants: F.meeting2Plants)]
        for m in sets { written += try await AwareE2E.meeting(title: "sc7 meeting", sources: m, labels: [], model: model).written.count }
        let tMeet = Date().timeIntervalSince(t0)
        let total = tMeet
        print("SC7 SWEEP: meetings \(Int(tMeet)) s, written \(written)")
        #expect(total < 600, "SC7: \(total) s")
    }

    @Test(.enabled(if: modelTestsEnabled && heldOutEnabled, "held-out: needs IONIAN_FLOW_MODEL_TESTS=1 and IONIAN_FLOW_HELDOUT=1")) func heldOutMeeting() async throws {
        await warmUp()
        let s = try await AwareE2E.meeting(title: "held-out 30-minute meeting", sources: AwareHeldOutFixture.meeting(file: "h.md"), labels: AwareHeldOutFixture.labels, model: model,
                                              projects: AwareHeldOutFixture.projects)
        s.print()
    }
}
}
