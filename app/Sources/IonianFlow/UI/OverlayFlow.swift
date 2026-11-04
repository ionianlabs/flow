import Foundation

// The pure side of the dictation overlay: when the pill opens, how fast new words are revealed, how the
// text wraps into lines and which lines are kept. No SwiftUI and no clock in here (time is passed in), so
// the unit tests can drive it.

/// Moving estimate of the time between bursts of live partials. Nemotron answers once per 560 ms chunk, a
/// few tokens a few ms apart; the next burst should start about when the last one has finished revealing.
struct BurstPacer {
    static let range: ClosedRange<Double> = 0.25...0.6
    /// A longer gap is a pause in speech, not the decoder's cadence.
    static let pause = 1.5
    private(set) var estimate = 0.56
    private var last: Double?

    /// A new burst arrived at `t` seconds.
    mutating func burst(at t: Double) {
        defer { last = t }
        guard let last else { return }
        let gap = t - last
        guard gap > 0, gap < Self.pause else { return }
        estimate = min(Self.range.upperBound, max(Self.range.lowerBound, 0.6 * estimate + 0.4 * gap))
    }

    /// How long the words of one burst take to appear.
    var duration: Double { min(Self.range.upperBound, max(Self.range.lowerBound, estimate)) }
}

/// Decides that the person is talking from the mic level, before the first partial exists (which takes
/// 0.6 to 1 s), so the pill can open early. Latches until the next dictation.
struct VoiceGate {
    /// RMS after the app's own smoothing: speech sits well above it, room noise below.
    var threshold: Float = 0.02
    /// One sample this loud is a voice, no need to wait for a second.
    var loud: Float = 0.06
    /// The press sound plays through the first moments; nothing counts before this.
    var grace = 0.3
    private(set) var open = false
    private var run = 0

    mutating func feed(level: Float, at t: Double) {
        guard !open, t >= grace else { return }
        run = level > threshold ? run + 1 : 0
        if run >= 2 || level > loud { open = true }
    }

    mutating func reset() { open = false; run = 0 }
}

struct OverlayWord: Equatable {
    var text: String
    /// Where the word starts to show, in seconds on the reveal clock; `-.infinity` for text that is just there.
    var start: Double
    /// The word ends a line of the source text.
    var breaksAfter = false
}

/// The words of the live text with their reveal schedule, and the greedy wrap into lines.
struct OverlayStream {
    /// Seconds one word takes to fade and rise in.
    static let wordFade = 0.25
    /// Tokens this close to the first of a burst belong to it.
    static let burstWindow = 0.15
    /// A late burst starts at most this far after it arrived, whatever is still being revealed.
    static let maxLag = 0.35
    /// Whole lines on screen while speaking, and one more above for the scroll.
    static let visibleLines = 2
    static let slackLines = 1

    private(set) var words: [OverlayWord] = []
    private(set) var lines: [Range<Int>] = []
    private(set) var pacer = BurstPacer()
    /// Index of the first word the last update changed.
    private(set) var changedFrom = 0
    private var burstStart = -Double.infinity
    private var burstBase = 0.0
    private var burstFirst = 0
    private var scheduledEnd = 0.0

    var isEmpty: Bool { words.isEmpty }
    var text: String { Self.join(words) }

    static func join(_ words: [OverlayWord]) -> String {
        var s = ""
        for (i, w) in words.enumerated() {
            s += w.text
            if i < words.count - 1 { s += w.breaksAfter ? "\n" : " " }
        }
        return s
    }

    /// Words with a flag for the end of a source line. Empty lines are dropped.
    static func tokens(_ text: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let ws = paragraph.split(separator: " ", omittingEmptySubsequences: true)
            for (i, w) in ws.enumerated() { out.append((String(w), i == ws.count - 1)) }
        }
        if !out.isEmpty { out[out.count - 1].1 = false }
        return out
    }

    /// Takes the engine's full text at time `now`. Words up to the common prefix keep their place and their
    /// schedule; the changed tail is scheduled again, spread over the expected time to the next burst.
    /// Returns where the reveal clock has to run to, or nil when nothing changed.
    mutating func update(_ text: String, now: Double) -> Double? {
        let new = Self.tokens(text)
        var common = 0
        while common < min(words.count, new.count), words[common].text == new[common].0, words[common].breaksAfter == new[common].1 { common += 1 }
        guard common != words.count || common != new.count else { return nil }
        changedFrom = common

        words.removeSubrange(common...)
        words += new[common...].map { OverlayWord(text: $0.0, start: .infinity, breaksAfter: $0.1) }

        if now - burstStart >= Self.burstWindow {
            pacer.burst(at: now)
            burstStart = now
            burstFirst = common
            burstBase = max(now, min(scheduledEnd, now + Self.maxLag))
        } else {
            burstFirst = min(burstFirst, common)
        }
        let n = max(1, words.count - burstFirst)
        let spread = max(0, pacer.duration - Self.wordFade)
        for i in burstFirst..<words.count where i >= common || words[i].start > now {
            words[i].start = max(now, burstBase + spread * Double(i - burstFirst) / Double(n))
        }
        scheduledEnd = max(scheduledEnd, (words.last?.start ?? now) + Self.wordFade)
        return scheduledEnd
    }

    mutating func reset() { self = OverlayStream() }

    // MARK: lines

    /// Greedy wrap of the words from word `first` (a line start) on. `widths` are the words alone; a space
    /// of width `space` sits between two words of a line.
    static func wrap(widths: [CGFloat], breaks: [Bool], space: CGFloat, width: CGFloat, from first: Int = 0) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = first
        var x: CGFloat = 0
        var i = first
        while i < widths.count {
            let add = (i == start ? 0 : space) + widths[i]
            if i > start, x + add > width {
                out.append(start..<i)
                start = i
                x = widths[i]
            } else {
                x += add
            }
            if breaks[i] {
                out.append(start..<(i + 1))
                start = i + 1
                x = 0
            }
            i += 1
        }
        if start < widths.count { out.append(start..<widths.count) }
        return out
    }

    /// Wraps again after the words changed from index `changed` on (or everything, for a new width): the
    /// lines that end before `changed` cannot change, so they stay; the rest is laid out again.
    mutating func rewrap(changedFrom changed: Int = 0, widths: [CGFloat], space: CGFloat, width: CGFloat) {
        var keep = lines.prefix { $0.upperBound < changed }.count
        if changed == 0 { keep = 0 }
        lines.removeSubrange(keep...)
        let first = lines.last?.upperBound ?? 0
        lines += Self.wrap(widths: widths, breaks: words.map(\.breaksAfter), space: space, width: width, from: first)
    }

    /// The lines worth a view: what is on screen plus the one scrolling out. Never fewer words, never a
    /// partial line.
    static func window(lineCount: Int) -> Range<Int> {
        max(0, lineCount - (visibleLines + slackLines))..<lineCount
    }
}
