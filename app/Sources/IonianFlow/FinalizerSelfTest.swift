import Foundation

// Unit C. Model-free checks for DictationFinal (guard, diff); called from EngineSelfTests.all().
// Mirrors the former Python pk_post.py guard(); the words are invented.

enum FinalizerSelfTest {
    private struct Table: WordFrequency {
        let words: [String: Double]
        func zipf(_ word: String, lang: WordFrequencyLanguage) -> Double { words[word.lowercased()] ?? 0 }
    }

    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { if !cond { ok = false; NSLog("FinalizerSelfTest FAIL: %@", what) } }
        let f = Table(words: ["sie": 6.1, "sehen": 5.5, "wir": 6.0, "morgen": 5.2, "the": 7.5, "red": 5.0, "door": 5.0, "cat": 5.3])
        func g(_ a: String, _ b: String) -> String { DictationFinal.guardReplacements(original: a, rescored: b, frequency: f) }

        check(g("sehen sie morgen", "sehen SRE morgen") == "sehen sie morgen", "common word replacement is reverted")
        check(g("we ask zorbex today", "we ask Zorbex today") == "we ask Zorbex today", "uncommon original: replacement kept")
        check(g("the red door", "the Quillnet") == "the red door", "multi-word span of common words reverted")
        check(g("the zarq door", "the Quillnet") == "the Quillnet", "span with one uncommon word kept")
        check(g("the cat", "the cat flurb") == "the cat flurb", "inserts are kept")
        check(g("the cat flurb", "the cat") == "the cat", "delete of an uncommon word is kept")
        check(g("wir sehen, sie", "wir sehen, SRE") == "wir sehen, sie", "punctuation is stripped before the lookup")
        check(g("sie said blorp", "SRE said Blorp") == "sie said Blorp", "two replacements decided separately")
        check(g("", "") == "", "empty")
        check(g("a b", "a b") == "a b", "unchanged text")
        return ok
    }
}
