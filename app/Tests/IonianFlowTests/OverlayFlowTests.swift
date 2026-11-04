import Foundation
import Testing
@testable import IonianFlow

/// The overlay's pure logic: burst pacing, the voice gate, word schedule and rewrites, line windows.
extension IonianFlowTests {
@Suite struct OverlayFlow {
    @Test func pacerFollowsTheCadenceAndStaysInRange() {
        var p = BurstPacer()
        #expect(p.duration == 0.56, "starts at the 560 ms chunk")
        var t = 0.0
        for _ in 0..<12 { t += 0.3; p.burst(at: t) }
        #expect(abs(p.duration - 0.3) < 0.02, "settles on a 300 ms cadence (\(p.duration))")
        for _ in 0..<12 { t += 0.05; p.burst(at: t) }
        #expect(p.duration == BurstPacer.range.lowerBound, "never below the clamp")
        for _ in 0..<5 { t += 0.58; p.burst(at: t) }
        #expect(p.duration > 0.5 && p.duration <= BurstPacer.range.upperBound)
    }

    @Test func pacerIgnoresPauses() {
        var p = BurstPacer()
        p.burst(at: 0); p.burst(at: 0.56)
        let before = p.duration
        p.burst(at: 10)  // the speaker stopped; this gap is not the cadence
        #expect(p.duration == before)
    }

    @Test func voiceGateNeedsTwoSamplesOrOneLoud() {
        var g = VoiceGate()
        g.feed(level: 0.5, at: 0.1)
        #expect(!g.open, "the press sound is ignored")
        g.feed(level: 0.03, at: 0.4); g.feed(level: 0.005, at: 0.5); g.feed(level: 0.03, at: 0.6)
        #expect(!g.open, "two samples that are not in a row do not count")
        g.feed(level: 0.03, at: 0.7)
        #expect(g.open)
        var loud = VoiceGate()
        loud.feed(level: 0.1, at: 0.5)
        #expect(loud.open, "one loud sample is a voice")
        loud.reset()
        #expect(!loud.open)
    }

    @Test func tokensKeepLineBreaks() {
        let t = OverlayStream.tokens("one two\n\nthree")
        #expect(t.map(\.0) == ["one", "two", "three"])
        #expect(t.map(\.1) == [false, true, false])
    }

    @Test func burstWordsAreSpreadOverTheExpectedInterval() {
        var s = OverlayStream()
        let until = s.update("Hello there my friend", now: 1.0)
        let starts = s.words.map(\.start)
        #expect(starts.first == 1.0)
        #expect(starts == starts.sorted() && Set(starts).count == 4, "one start per word, in order")
        let d = s.pacer.duration
        #expect(starts.last! < 1.0 + d - OverlayStream.wordFade + 0.001)
        #expect(until != nil && abs(until! - (starts.last! + OverlayStream.wordFade)) < 0.001)
    }

    @Test func tokensOfOneBurstShareIt() {
        var s = OverlayStream()
        _ = s.update("Hello", now: 1.0)
        _ = s.update("Hello there", now: 1.05)
        #expect(s.pacer.estimate == 0.56, "a late token is not a second burst")
        #expect(s.words.count == 2 && s.words[1].start >= 1.05)
    }

    @Test func nextBurstStartsWhenTheLastOneEnds() {
        var s = OverlayStream()
        _ = s.update("one two three four five six", now: 0)
        let end = s.words.last!.start + OverlayStream.wordFade
        _ = s.update("one two three four five six seven", now: 0.3)
        #expect(s.words[6].start >= end - 0.0001 || s.words[6].start >= 0.3 + OverlayStream.maxLag - 0.0001 || end - 0.3 <= OverlayStream.maxLag)
        #expect(s.words[6].start <= 0.3 + OverlayStream.maxLag + 0.0001, "the lag is capped")
    }

    @Test func rewriteOnlyReschedulesTheChangedTail() {
        var s = OverlayStream()
        _ = s.update("we should meet at tree", now: 0)
        let kept = Array(s.words[..<4])
        _ = s.update("we should meet at three o'clock", now: 0.6)
        #expect(s.changedFrom == 4)
        #expect(Array(s.words[..<4]) == kept, "earlier words keep their text and schedule")
        #expect(s.words[4].text == "three" && s.words[4].start >= 0.6, "the changed word shows again")
        #expect(s.update("we should meet at three o'clock", now: 1.2) == nil, "same text, nothing to do")
    }

    @Test func shrinkingTextIsARewrite() {
        var s = OverlayStream()
        _ = s.update("a b c d", now: 0)
        _ = s.update("a b", now: 0.6)
        #expect(s.words.map(\.text) == ["a", "b"] && s.changedFrom == 2)
    }

    @Test func wrapIsGreedyAndHonoursBreaks() {
        let w = [CGFloat](repeating: 10, count: 6)
        let lines = OverlayStream.wrap(widths: w, breaks: [false, false, false, false, false, false], space: 2, width: 34)
        #expect(lines == [0..<3, 3..<6], "three words of 10 plus two spaces are 34")
        let hard = OverlayStream.wrap(widths: w, breaks: [false, true, false, false, false, false], space: 2, width: 100)
        #expect(hard == [0..<2, 2..<6])
    }

    @Test func appendingNeverMovesEarlierLines() {
        var s = OverlayStream()
        _ = s.update(String(repeating: "word ", count: 12), now: 0)
        func wrap(from changed: Int) {
            s.rewrap(changedFrom: changed, widths: s.words.map { CGFloat($0.text.count) * 8 }, space: 4, width: 100)
        }
        wrap(from: 0)
        let before = s.lines
        #expect(before.count > 2)
        _ = s.update(String(repeating: "word ", count: 13), now: 0.6)
        wrap(from: s.changedFrom)
        #expect(Array(s.lines.dropLast()).starts(with: before.dropLast()), "full lines stay as they were")
        #expect(s.lines.last!.upperBound == 13)
        var fresh = s
        fresh.rewrap(changedFrom: 0, widths: s.words.map { CGFloat($0.text.count) * 8 }, space: 4, width: 100)
        #expect(fresh.lines == s.lines, "the cached wrap equals a wrap from scratch")
    }

    @Test func rewriteRewrapsFromTheChangedLine() {
        var s = OverlayStream()
        _ = s.update("aa bb cc dd ee ff gg hh", now: 0)
        let widths: ([OverlayWord]) -> [CGFloat] = { $0.map { CGFloat($0.text.count) * 10 } }
        s.rewrap(changedFrom: 0, widths: widths(s.words), space: 5, width: 50)
        let first = s.lines.first!
        _ = s.update("aa bb cc dd ee ff gg hhhhhh", now: 0.6)
        s.rewrap(changedFrom: s.changedFrom, widths: widths(s.words), space: 5, width: 50)
        #expect(s.lines.first == first)
        var scratch = s
        scratch.rewrap(changedFrom: 0, widths: widths(s.words), space: 5, width: 50)
        #expect(scratch.lines == s.lines)
    }

    @Test func windowIsWholeLinesTwoVisiblePlusOne() {
        #expect(OverlayStream.window(lineCount: 0) == 0..<0)
        #expect(OverlayStream.window(lineCount: 1) == 0..<1)
        #expect(OverlayStream.window(lineCount: 3) == 0..<3)
        #expect(OverlayStream.window(lineCount: 10) == 7..<10)
    }
}
}
