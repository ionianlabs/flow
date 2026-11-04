import Foundation
import Testing
@testable import IonianFlow

// Fast checks of the live segment tracker, language codes and PCM conversion; no models.

extension IonianFlowTests {
@Suite struct NativeLiveChecks {
    @Test func segmentTracker() {
        func check(_ name: String, _ cond: Bool) { #expect(cond, "\(name)") }
        func tok(_ f: Int, _ p: String) -> LiveToken { LiveToken(frame: f, piece: p) }
        typealias T = SegmentTracker

        // Pieces
        check("punct", T.isPunct(".") && T.isPunct("▁") && T.isPunct("…") && !T.isPunct("▁a") && !T.isPunct("7"))
        check("latin ok", !T.hasNonLatin("Grüße, naïve café œuvre ẞ ł"))
        check("latin cyrillic", T.hasNonLatin("привет"))
        check("latin devanagari", T.hasNonLatin("Hello हेलो"))
        check("latin greek", T.hasNonLatin("α"))
        check("latin digits and symbols ok", !T.hasNonLatin("100 € – „ja“"))
        check("decode", T.decode(pieces: ["▁Hel", "lo", "▁", "▁world", "."]) == "Hello world.")
        check("display seg0 keeps", T.display(". Hi", segment: 0) == ". Hi")
        check("display strips", T.display(".,? … Hi there", segment: 1) == "Hi there")
        check("display keeps inner", T.display("Hi. There", segment: 2) == "Hi. There")

        // Cut math: sample / 1280, at least previous + 1, at least 1
        var c = T()
        c.addCut(sample: 0); c.addCut(sample: 1279); c.addCut(sample: 12800); c.addCut(sample: 12801)
        check("cut math", c.cuts == [1, 2, 10, 11])
        check("seconds", T.seconds(5) == 0.4 && T.seconds(nil) == nil && T.seconds(13) == 1.04)

        // No cuts: one segment, text per change, final at the end
        var t = T()
        var o = t.step(tokens: [tok(0, "▁Hi")], frames: 7)
        check("step text", o == [.text(segment: 0, text: "Hi")])
        o = t.step(tokens: [], frames: 14)
        check("step no change", o.isEmpty)
        o = t.end(tokens: [tok(15, ".")])
        check("end", o == [.cut(segment: 0, text: "Hi.", first: 0, last: 0)])

        // Cut at frame 10: the next word moves on at once
        t = T()
        t.addCut(sample: 10 * 1280)
        o = t.step(tokens: [tok(1, "▁one"), tok(3, "▁two"), tok(11, "▁three")], frames: 14)
        check("cut at word", o == [.cut(segment: 0, text: "one two", first: 1, last: 3), .text(segment: 1, text: "three")])
        // The cut waits for the next word
        t = T()
        t.addCut(sample: 10 * 1280)
        _ = t.step(tokens: [tok(1, "▁one")], frames: 7)
        o = t.step(tokens: [tok(11, "▁three")], frames: 12)
        check("cut when word arrives", o.first == .cut(segment: 0, text: "one", first: 1, last: 1))

        // PUNCT_HOLD: a full stop after the cut still belongs to the previous segment; the hold ends the segment
        t = T()
        t.addCut(sample: 10 * 1280)
        _ = t.step(tokens: [tok(1, "▁one")], frames: 7)
        o = t.step(tokens: [], frames: 10 + T.punctHold - 1)
        check("hold waits", o.isEmpty)
        o = t.step(tokens: [tok(12, ".")], frames: 17)
        check("punct stays in segment 0", o == [.text(segment: 0, text: "one.")])
        o = t.step(tokens: [], frames: 10 + T.punctHold)
        check("hold ends", o == [.cut(segment: 0, text: "one.", first: 1, last: 1), .text(segment: 1, text: "")])

        // Punctuation that slips into the next segment is stripped there
        t = T()
        t.addCut(sample: 10 * 1280)
        _ = t.step(tokens: [tok(1, "▁one")], frames: 7)
        o = t.step(tokens: [tok(11, "▁and"), tok(12, "▁so")], frames: 14)
        check("next segment", o.contains(.text(segment: 1, text: "and so")))
        t = T()
        t.addCut(sample: 3 * 1280)
        o = t.step(tokens: [tok(1, "▁a"), tok(5, "."), tok(6, "▁b")], frames: 7)
        check("punct before next word goes with previous", o.first == .cut(segment: 0, text: "a.", first: 1, last: 1))
        t = T()
        t.addCut(sample: 3 * 1280)
        _ = t.step(tokens: [tok(1, "▁a")], frames: 7)
        _ = t.step(tokens: [tok(8, "▁b")], frames: 8)
        check("cut after decoder passed it", t.segment == 1)

        // End forces open cuts; an empty segment has no times
        t = T()
        t.addCut(sample: 5 * 1280)
        _ = t.step(tokens: [tok(1, "▁x")], frames: 3)
        o = t.end(tokens: [])
        check("end forces", o == [.cut(segment: 0, text: "x", first: 1, last: 1), .cut(segment: 1, text: "", first: nil, last: nil)])

        // Language codes, PCM
        check("lang", nativeLanguageCode("") == "auto" && nativeLanguageCode("de") == "de-DE" && nativeLanguageCode("en-GB") == "en-GB")
        check("pcm", LiveStream.floats(Data([0x00, 0x40, 0x00, 0xC0])) == [0.5, -0.5])
    }
}
}
