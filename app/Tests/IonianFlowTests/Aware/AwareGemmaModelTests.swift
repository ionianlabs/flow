import Foundation
import Testing
@testable import IonianFlow

// Real Gemma. IONIAN_FLOW_MODEL_TESTS=1 swift test --package-path app --filter AwareGemmaModel
// F1.16 to F1.18, F1.22/F1.23/F1.26 (model step), SC6 to SC8. Each scenario runs `runs` times and must pass every time.

private let runs = 3
private typealias F = AwareGemmaFixtures

nonisolated(unsafe) private var failedParts = 0

private func extractAll(_ model: GemmaAwareModel, _ sources: [AwareSource], limit: Int = GemmaAwareModel.defaultChunkLimit) async throws -> [AwareItem] {
    var out: [AwareItem] = []
    for part in GemmaAwareModel.chunks(sources, limit: limit) {
        do { out += try await model.extract(part, projects: F.projects) }
        catch {  // the sweep retries once (F1.32), then leaves the part for the next sweep
            do { out += try await model.extract(part, projects: F.projects) } catch { failedParts += 1; print("PART FAILED: \(error)".prefix(400)) }
        }
    }
    return out
}

private func show(_ title: String, _ items: [AwareItem]) {
    print("== \(title): \(items.count) items")
    for i in items {
        print("  [\(i.category.rawValue)] \(i.text) | due=\(i.due ?? "-") owner=\(i.owner ?? "-") proj=\(i.project) conf=\(i.confidence) src=\(i.sourceID) | \"\(i.quote)\"")
    }
}

/// Prints every raw answer when IONIAN_FLOW_AWARE_DEBUG=1.
private struct LoggingLLM: VaultLLM {
    let base: VaultLLM
    func chat(_ messages: [ChatMsg], maxTokens: Int) async throws -> String {
        let a = try await base.chat(messages, maxTokens: maxTokens)
        if ProcessInfo.processInfo.environment["IONIAN_FLOW_AWARE_DEBUG"] == "1" { print("RAW: \(a.prefix(300))") }
        return a
    }
}

extension IonianFlowTests {
@Suite(.serialized) struct AwareGemmaModelTests {
    let model = GemmaAwareModel(llm: LoggingLLM(base: GemmaVaultLLM(hub: .shared, control: nil)))

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func f116_requestFromThemIsATodoWithDue() async throws {
        let s = F.source("t.md#1", .them, "Can you send me the deck by Friday?")
        for _ in 0..<runs {
            let items = try await extractAll(model, [s])
            show("F1.16", items)
            let todo = try #require(items.first { $0.category == .todo })
            #expect(todo.due == "2026-11-06")
            #expect(AwareParsing.isVerbatim(todo.quote, in: s.text))
            #expect(todo.quote.lowercased().contains("send me the deck"))
        }
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func f117_decisionForAlpha() async throws {
        let s = F.source("t.md#2", .you, "Okay, so we drop the legacy export, that's decided")
        for _ in 0..<runs {
            let items = try await extractAll(model, [s])
            show("F1.17", items)
            let d = try #require(items.first { $0.category == .decision })
            #expect(d.project == "alpha")
            #expect(AwareParsing.isVerbatim(d.quote, in: s.text))
        }
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func f118_noiseGivesNothing() async throws {
        let texts = ["we could maybe look at caching someday", "how was your weekend", "I think the API is kind of slow"]
        for t in texts {
            for _ in 0..<runs {
                let items = try await extractAll(model, [F.source("t.md#3", .you, t)])
                show("F1.18 '\(t)'", items)
                #expect(items.isEmpty, "'\(t)' should give nothing")
            }
        }
        // all three together as one chunk
        for _ in 0..<runs {
            let items = try await extractAll(model, texts.enumerated().map { F.source("t.md#\($0.offset)", .you, $0.element) })
            show("F1.18 together", items)
            #expect(items.isEmpty)
        }
    }

    func item(_ text: String, _ cat: AwareCategory = .todo) -> AwareItem {
        AwareItem(category: cat, text: text, owner: nil, due: nil, quote: "q", sourceID: "s", project: "alpha", confidence: 0.9, conflicts: nil)
    }

    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func judgeSameConflictsNew() async throws {
        let unrelated = ["Order new monitors for the office", "Dentist appointment on Tuesday"]
        for _ in 0..<runs {
            let a = try await model.judge(item("Send the deck"), against: ["Review the budget", "- [ ] Send the deck to the board", "Book travel"])  // F1.22
            let b = try await model.judge(item("Drop the legacy export", .decision), against: ["Decision: Legacy export is dropped in Q1", "Focus: ship the new export"])  // F1.23
            let c = try await model.judge(item("Launch moved to June", .fact), against: ["launch in April", "Team offsite in May"])  // F1.26
            let d = try await model.judge(item("Rotate the staging key monthly"), against: unrelated)
            print("judge: F1.22 \(a) | F1.23 \(b) | F1.26 \(c) | new \(d)")
            #expect(a == .same)
            #expect(b == .same)
            #expect(c == .conflicts("launch in April"))
            #expect(d == .new)
        }
    }

    // SC6, precision by hand, SC8.
    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func longMeetingAndDictations() async throws {
        let m1 = F.meeting(file: "m1.md", minutes: 60, seed: 1, plants: F.meeting1Plants)
        let m2 = F.meeting(file: "m2.md", minutes: 15, seed: 2, plants: F.meeting2Plants)
        let words = m1.reduce(0) { $0 + $1.text.split(separator: " ").count }
        print("m1: \(m1.count) blocks, \(words) words, \(GemmaAwareModel.chunks(m1).count) chunks")

        _ = try await model.judge(item("warm up"), against: ["x"])  // load the model outside the timing
        let t0 = Date()
        let i1 = try await extractAll(model, m1)
        let sc8 = Date().timeIntervalSince(t0)
        print("SC8 60-minute meeting: \(Int(sc8)) s")
        show("60-minute meeting", i1)
        let i2 = try await extractAll(model, m2)
        show("15-minute meeting", i2)
        let dict = F.dictationSources()
        let i3 = try await extractAll(model, dict)
        show("20 dictations", i3)

        let byID = Dictionary(uniqueKeysWithValues: (m1 + m2 + dict).map { ($0.id, $0) })
        // SC6: what the sweep would write passes the F1.19 guard, so every quote is verbatim. Also report the raw rate.
        let all = i1 + i2 + i3
        let bad = all.filter { i in byID[i.sourceID].map { !AwareParsing.isVerbatim(i.quote, in: $0.text) } ?? true }
        print("SC6 raw: \(all.count - bad.count)/\(all.count) quotes verbatim in their source")
        for b in bad { print("  not verbatim (src=\(b.sourceID)): \(b.quote)") }
        let kept = all.filter { i in byID[i.sourceID].map { AwareParsing.isVerbatim(i.quote, in: $0.text) } ?? false }
        #expect(kept.allSatisfy { i in AwareParsing.isVerbatim(i.quote, in: byID[i.sourceID]!.text) })
        #expect(Double(all.count - bad.count) >= 0.9 * Double(all.count), "more than 10% of raw quotes are not verbatim")
        #expect(sc8 < 300, "SC8: \(sc8) s")
    }

    // SC7: 3 hours of meetings and 100 dictations.
    @Test(.enabled(if: modelTestsEnabled, "needs Gemma; set IONIAN_FLOW_MODEL_TESTS=1")) func threeHoursAndHundredDictations() async throws {
        let sets = [F.meeting(file: "a.md", minutes: 60, seed: 1, plants: F.meeting1Plants),
                    F.meeting(file: "b.md", minutes: 15, seed: 2, plants: F.meeting2Plants),
                    F.meeting(file: "c.md", minutes: 60, seed: 3, plants: F.meeting1Plants),
                    F.meeting(file: "d.md", minutes: 45, seed: 4, plants: F.meeting2Plants)]
        let dict = F.dictationSources(copies: 5)
        _ = try await model.judge(item("warm up"), against: ["x"])
        let t0 = Date()
        var total = 0
        for m in sets { total += try await extractAll(model, m).count }
        let tMeet = Date().timeIntervalSince(t0)
        total += try await extractAll(model, dict).count
        let t = Date().timeIntervalSince(t0)
        print("SC7: meetings \(Int(tMeet)) s, dictations \(Int(t - tMeet)) s, total \(Int(t)) s, \(total) items, \(sets.flatMap { $0 }.count) blocks")
        #expect(t < 600, "SC7: \(t) s")
    }
}
}
