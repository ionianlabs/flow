import Foundation
import Testing
@testable import IonianFlow

// Crafted cases; the expected values are what asr/bench_wer.normalize gave in Python (2026-11-03), and
// WER values worked out by hand (jiwer's corpus WER is sum of edits over sum of reference words).

extension IonianFlowTests {
@Suite struct WERScoring {
    @Test func scoring() {
        func check(_ name: String, _ cond: Bool) { #expect(cond, "\(name)") }
        typealias W = WERScore
        let norm: [(String, String)] = [
            ("Hello, World!", "hello world"),
            ("It\u{2019}s  Tom's `bike\u{00b4}", "its toms bike"),
            ("don't_stop\u{2014}believing", "dont stop believing"),
            ("Gr\u{00f6}\u{00df}e Stra\u{00df}e \u{00c4}\u{00d6}\u{00dc}", "gr\u{00f6}\u{00df}e stra\u{00df}e \u{00e4}\u{00f6}\u{00fc}"),
            ("\u{ff26}\u{ff35}\u{ff2c}\u{ff2c}\u{3000}\u{ff57}\u{ff49}\u{ff44}\u{ff54}\u{ff48} \u{00bd} \u{fb01}sh", "full width 1 2 fish"),
            ("3,5 % (ca.) 12:30 Uhr", "3 5 ca 12 30 uhr"),
            ("  \t\n ", ""),
            ("x\u{00b2}  y\u{2082} \u{2014} z", "x2 y2 z"),
            ("e\u{0301}cole \u{00c9}COLE", "\u{00e9}cole \u{00e9}cole"),
            ("\u{0130}stanbul \u{01c5}", "i stanbul d\u{017e}"),
            ("a\u{00a0}b\u{2003}c\u{200b}d", "a b c d"),
            ("na\u{00ef}ve\u{2014}caf\u{00e9}\u{2026} \u{201c}quoted\u{201d} \u{00ab}guillemets\u{00bb}", "na\u{00ef}ve caf\u{00e9} quoted guillemets"),
            ("\u{65e5}\u{672c}\u{8a9e} \u{30c6}\u{30b9}\u{30c8} 123", "\u{65e5}\u{672c}\u{8a9e} \u{30c6}\u{30b9}\u{30c8} 123"),
            ("\u{03a3}\u{0391}\u{03a3} \u{00df} \u{1e9e}", "\u{03c3}\u{03b1}\u{03c2} \u{00df} \u{00df}"),
        ]
        for (i, (input, want)) in norm.enumerated() { check("normalize \(i): \(W.normalize(input).debugDescription)", W.normalize(input) == want) }
        check("edits identical", W.edits(["a", "b"], ["a", "b"]) == 0)
        check("edits kitten", W.edits(Array("kitten"), Array("sitting")) == 3)
        check("edits empty ref", W.edits([String](), ["a", "b"]) == 2)
        check("edits empty hyp", W.edits(["a", "b", "c"], [String]()) == 3)
        let w1 = W.wer(refs: ["the cat sat on the mat", "Hallo Welt"], hyps: ["the cat sat on mat", "hallo, Welt wie geht's"])  // 1 del + 2 ins over 8 words
        check("wer corpus", abs((w1 ?? -1) - 37.5) < 1e-9)
        let w2 = W.wer(refs: ["a b c d"], hyps: ["a x c"])  // 1 sub + 1 del over 4
        check("wer sub+del", abs((w2 ?? -1) - 50.0) < 1e-9)
        check("wer no ref words", W.wer(refs: ["..."], hyps: ["x"]) == nil)
        let table = W.scoreDictationTable(
            manifest: ["a": ["dataset": "fleurs", "lang": "de", "ref": "ein kleiner Test"], "b": ["dataset": "voxpopuli", "lang": "en", "ref": "one two three four"]],
            runs: [("e2e", ["a", "b"], ["a": ["text": "Ein kleiner Text."], "b": ["text": "one three four"]])])
        check("score table", table.contains("all/all                2       28.57%") && table.contains("fleurs/de              1       33.33%"))
    }
}
}
