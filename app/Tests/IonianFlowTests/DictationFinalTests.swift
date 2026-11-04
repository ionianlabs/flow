import Foundation
import Testing
@testable import IonianFlow

// Unit C. Model-free checks for DictationFinal (guard, diff); run by `swift test`.
// Mirrors the former Python pk_post.py guard(); the words are invented.

extension IonianFlowTests {
@Suite struct DictationFinalGuard {
    private struct Table: WordFrequency {
        let words: [String: Double]
        func zipf(_ word: String, lang: WordFrequencyLanguage) -> Double { words[word.lowercased()] ?? 0 }
    }

    @Test func guardReplacements() {
        let f = Table(words: ["sie": 6.1, "sehen": 5.5, "wir": 6.0, "morgen": 5.2, "the": 7.5, "red": 5.0, "door": 5.0, "cat": 5.3])
        func g(_ a: String, _ b: String) -> String { DictationFinal.guardReplacements(original: a, rescored: b, frequency: f) }

        #expect(g("sehen sie morgen", "sehen SRE morgen") == "sehen sie morgen", "common word replacement is reverted")
        #expect(g("we ask zorbex today", "we ask Zorbex today") == "we ask Zorbex today", "uncommon original: replacement kept")
        #expect(g("the red door", "the Quillnet") == "the red door", "multi-word span of common words reverted")
        #expect(g("the zarq door", "the Quillnet") == "the Quillnet", "span with one uncommon word kept")
        #expect(g("the cat", "the cat flurb") == "the cat flurb", "inserts are kept")
        #expect(g("the cat flurb", "the cat") == "the cat", "delete of an uncommon word is kept")
        #expect(g("wir sehen, sie", "wir sehen, SRE") == "wir sehen, sie", "punctuation is stripped before the lookup")
        #expect(g("sie said blorp", "SRE said Blorp") == "sie said Blorp", "two replacements decided separately")
        #expect(g("", "") == "", "empty")
        #expect(g("a b", "a b") == "a b", "unchanged text")
    }
}
}
