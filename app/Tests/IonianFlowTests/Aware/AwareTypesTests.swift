import Foundation
import Testing
@testable import IonianFlow

@Suite struct AwareTypesTests {
    // F1.32 (parse part): a plain object parses, nil when it does not.
    @Test func parsesItems() throws {
        let json = #"{"items":[{"category":"todo","text":"Send the deck","owner":null,"due":"2026-11-06","quote":"send me the deck","source":"s1","project":"alpha","confidence":0.82}]}"#
        let items = try #require(AwareParsing.items(json))
        #expect(items.count == 1)
        #expect(items[0] == AwareItem(category: .todo, text: "Send the deck", owner: nil, due: "2026-11-06",
                                         quote: "send me the deck", sourceID: "s1", project: "alpha",
                                         confidence: 0.82, conflicts: nil))
    }

    @Test func toleratesProseAndFence() throws {
        let obj = #"{"items":[]}"#
        #expect(try #require(AwareParsing.items("Here you go:\n```json\n\(obj)\n```\nDone.")).isEmpty)
        #expect(try #require(AwareParsing.items("Sure. \(obj) Hope it helps")).isEmpty)
    }

    @Test func unparsableIsNil() {
        #expect(AwareParsing.items("not json at all") == nil)
        #expect(AwareParsing.items(#"{"items":"x"}"#) == nil)
        #expect(AwareParsing.items(#"{"items":[{"category":"todo"}"#) == nil)
        #expect(AwareParsing.verdict("???") == nil)
    }

    @Test func unknownCategoryDropsThatItemOnly() throws {
        let json = #"{"items":[{"category":"idea","text":"A","quote":"a","source":"s","project":"alpha","confidence":0.9},{"category":"fact","text":"B","quote":"b","source":"s","project":"beta","confidence":0.7}]}"#
        let items = try #require(AwareParsing.items(json))
        #expect(items.map(\.text) == ["B"])
    }

    @Test func parsesVerdicts() {
        #expect(AwareParsing.verdict(#"{"verdict":"same"}"#) == .same)
        #expect(AwareParsing.verdict(#"{"verdict":"new"}"#) == .new)
        #expect(AwareParsing.verdict(#"ok {"verdict":"conflicts","line":"launch in April"}"#) == .conflicts("launch in April"))
        #expect(AwareParsing.verdict(#"{"verdict":"maybe"}"#) == nil)
    }

    // F1.19: verbatim guard.
    @Test func verbatimGuard() {
        let text = "Sam:  Can you send me\nthe deck by Friday?  Thanks."
        #expect(AwareParsing.isVerbatim("can you SEND me the deck by friday?", in: text))
        #expect(!AwareParsing.isVerbatim("send her the deck", in: text))
        #expect(!AwareParsing.isVerbatim("   ", in: text))
    }
}
