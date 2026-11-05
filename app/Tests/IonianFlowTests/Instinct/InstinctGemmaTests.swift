import Foundation
import Testing
@testable import IonianFlow

private final class FakeLLM: VaultLLM, @unchecked Sendable {
    var answers: [String]
    var calls: [(messages: [ChatMsg], maxTokens: Int)] = []
    init(_ answers: [String]) { self.answers = answers }
    func chat(_ messages: [ChatMsg], maxTokens: Int) async throws -> String {
        calls.append((messages, maxTokens))
        return answers.isEmpty ? "" : answers.removeFirst()
    }
}

func instinctTestDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10, _ min: Int = 14) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

@Suite struct InstinctGemmaTests {
    let thu = instinctTestDate(2026, 11, 5)
    var sources: [InstinctSource] {
        [InstinctSource(id: "m.md#3", kind: .transcript(fileName: "m.md"), time: thu, speaker: .them,
                        text: "Can you send me the deck by Friday?"),
         InstinctSource(id: "d7", kind: .dictation(app: "Notes", bundle: "com.apple.Notes"), time: thu, speaker: nil,
                        text: "Remind me to renew the vendor contract")]
    }
    let projects = [InstinctProjectHint(slug: "alpha", description: "The export rewrite", focus: "Ship in Q1")]

    @Test func extractPromptRendersSourcesAndProjects() async throws {
        let llm = FakeLLM([#"{"items":[]}"#])
        let items = try await GemmaInstinctModel(llm: llm).extract(sources, projects: projects)
        #expect(items.isEmpty)
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].maxTokens == 800)
        let all = llm.calls[0].messages.map(\.content).joined(separator: "\n")
        #expect(all.contains("Source S1 |"))
        #expect(all.contains("Source S2 |"))
        #expect(all.contains("2026-11-05 Thursday"))
        #expect(all.contains("Them"))
        #expect(all.contains("Can you send me the deck by Friday?"))
        #expect(all.contains("Notes"))
        #expect(all.contains("alpha: The export rewrite; Ship in Q1"))
        #expect(all.contains(#"{"items":["#))
    }

    @Test func extractParsesItems() async throws {
        let json = #"{"items":[{"category":"todo","text":"Send the deck","due":"2026-11-06","quote":"send me the deck by Friday","source":"m.md#3","project":"none","confidence":0.9}]}"#
        let items = try await GemmaInstinctModel(llm: FakeLLM([json])).extract(sources, projects: projects)
        #expect(items.count == 1)
        #expect(items[0].due == "2026-11-06")
        #expect(items[0].sourceID == "m.md#3")
    }

    @Test func sourceNumbersMapBackToRealIDs() async throws {
        let json = #"{"items":[{"category":"todo","text":"Renew","quote":"renew the vendor contract","source":"S2","project":"none","confidence":0.9},{"category":"todo","text":"Send","quote":"send me the deck by Friday","source":"[S9]","project":"none","confidence":0.9},{"category":"fact","text":"X","quote":"not in any source","source":"S1","project":"none","confidence":0.9}]}"#
        let items = try await GemmaInstinctModel(llm: FakeLLM([json])).extract(sources, projects: projects)
        #expect(items.map(\.sourceID) == ["d7", "m.md#3", "S1"])  // wrong number: found by quote; no source holds the quote: left for the verbatim guard
    }

    @Test func extractSendsWorkedExamplesBeforeTheRealRequest() async throws {
        let llm = FakeLLM([#"{"items":[]}"#])
        _ = try await GemmaInstinctModel(llm: llm).extract(sources, projects: projects)
        let roles = llm.calls[0].messages.map(\.role)
        #expect(roles == ["system", "user", "assistant", "user", "assistant", "user"])
    }

    @Test func extractWithNoProjectsStillBuildsPrompt() async throws {
        let llm = FakeLLM([#"{"items":[]}"#])
        _ = try await GemmaInstinctModel(llm: llm).extract(sources, projects: [])
        #expect(llm.calls[0].messages.map(\.content).joined().contains("none"))
    }

    @Test func extractUnparsableThrows() async {
        await #expect(throws: InstinctModelError.self) {
            _ = try await GemmaInstinctModel(llm: FakeLLM(["I could not find anything."])).extract(sources, projects: projects)
        }
    }

    @Test func judgePromptListsItemAndLines() async throws {
        let llm = FakeLLM([#"{"verdict":"conflicts","line":"launch in April"}"#])
        let item = InstinctItem(category: .fact, text: "Launch moved to June", owner: nil, due: nil, quote: "q",
                                sourceID: "s", project: "alpha", confidence: 0.9, conflicts: nil)
        let v = try await GemmaInstinctModel(llm: llm).judge(item, against: ["launch in April", "Send the deck"])
        #expect(v == .conflicts("launch in April"))
        #expect(llm.calls[0].maxTokens == 60)
        let all = llm.calls[0].messages.map(\.content).joined(separator: "\n")
        #expect(all.contains("Launch moved to June"))
        #expect(all.contains("launch in April"))
        #expect(all.contains("Send the deck"))
        #expect(all.contains(#"{"verdict":"same"}"#))
    }

    @Test func judgeCapsLinesAtTwenty() async throws {
        let llm = FakeLLM([#"{"verdict":"new"}"#])
        let item = InstinctItem(category: .todo, text: "X", owner: nil, due: nil, quote: "q", sourceID: "s", project: "none", confidence: 1, conflicts: nil)
        _ = try await GemmaInstinctModel(llm: llm).judge(item, against: (1...30).map { "line number \($0)x" })
        let all = llm.calls[0].messages.map(\.content).joined(separator: "\n")
        #expect(all.contains("line number 20x"))
        #expect(!all.contains("line number 21x"))
    }

    @Test func judgeUnparsableThrows() async {
        let item = InstinctItem(category: .todo, text: "X", owner: nil, due: nil, quote: "q", sourceID: "s", project: "none", confidence: 1, conflicts: nil)
        await #expect(throws: InstinctModelError.self) {
            _ = try await GemmaInstinctModel(llm: FakeLLM(["maybe"])).judge(item, against: ["a"])
        }
    }

    @Test func judgeWithNoLinesIsNewWithoutAsking() async throws {
        let llm = FakeLLM([])
        let item = InstinctItem(category: .todo, text: "X", owner: nil, due: nil, quote: "q", sourceID: "s", project: "none", confidence: 1, conflicts: nil)
        #expect(try await GemmaInstinctModel(llm: llm).judge(item, against: []) == .new)
        #expect(llm.calls.isEmpty)
    }
}

extension InstinctGemmaTests {
    @Test func chunksKeepOrderAndNeverSplitASource() {
        let src = (0..<10).map { InstinctSource(id: "s\($0)", kind: .transcript(fileName: "m"), time: Date(), speaker: .you, text: String(repeating: "a", count: 400)) }
        let parts = GemmaInstinctModel.chunks(src, limit: 1000)
        #expect(parts.map(\.count) == [2, 2, 2, 2, 2])
        #expect(parts.flatMap { $0 }.map(\.id) == src.map(\.id))
        let big = [InstinctSource(id: "b", kind: .transcript(fileName: "m"), time: Date(), speaker: .you, text: String(repeating: "a", count: 5000))]
        #expect(GemmaInstinctModel.chunks(big, limit: 1000).count == 1)
        #expect(GemmaInstinctModel.chunks([], limit: 1000).isEmpty)
        let many = (0..<20).map { InstinctSource(id: "s\($0)", kind: .transcript(fileName: "m"), time: Date(), speaker: .you, text: "a") }
        #expect(GemmaInstinctModel.chunks(many, limit: 1000, maxSources: 8).map(\.count) == [8, 8, 4])
    }

    @Test func verificationAnswersParse() {
        #expect(InstinctParsing.verification(#"{"keep":"yes","project":"no"}"#) == InstinctVerification(holds: true, belongsToProject: false))
        #expect(InstinctParsing.verification("```json\n{\"keep\":\"no\",\"project\":\"yes\"}\n```") == InstinctVerification(holds: false, belongsToProject: true))
        #expect(InstinctParsing.verification(#"{"keep":true}"#) == InstinctVerification(holds: true, belongsToProject: false))
        #expect(InstinctParsing.verification("maybe") == nil)
        #expect(InstinctParsing.verification(#"{"keep":"perhaps"}"#) == nil)
    }

    @Test func verifyPromptShowsQuoteSpeakerAndProject() {
        let item = InstinctItem(category: .fact, text: "t", owner: nil, due: nil, quote: "the quote", sourceID: "s", project: "alpha", confidence: 0.9, conflicts: nil)
        let hint = InstinctProjectHint(slug: "alpha", description: "Data migration", focus: "Cut over")
        let user = GemmaInstinctModel.verifyMessages(item, speaker: .them, project: hint).last!.content
        #expect(user.contains("said by Them") && user.contains("\"the quote\"") && user.contains("Project alpha: Data migration; Cut over"))
        #expect(GemmaInstinctModel.verifyMessages(item, speaker: nil, project: nil).last!.content.contains("Project: none"))
    }
}
