import SwiftUI

/// Timing and phases of the Instinct stage (F3.13 to F3.14): a soft wave of faint words, and a few fragments that
/// lift out of it and settle as crisp lines. Pure: time in, what to draw out. Motion is slow and continuous
/// (MOT-01), eased with `motion.easing.soft-out`, and Reduce Motion selects one composed still frame (MOT-04).
enum InstinctStage {
    enum Mode: Equatable {
        /// Instinct is off: the stage loops slowly and shows what it would do.
        case teaser
        /// The switch was just turned on: the stream gathers, the lines settle, the stage resolves into the status.
        case enabling
        /// Instinct is on: a very slow, nearly still wave.
        case on
    }

    static let lineCount = 3
    static let enableDuration: TimeInterval = 1.8
    static let teaserPeriod: TimeInterval = 16
    /// Radians per second of the wave: one slow swell, about 18 s per crest.
    static let waveRate = 0.35

    /// Everything the drawing needs for one instant.
    struct Frame: Equatable {
        /// Phase of the wave and the drift of the words, in seconds on a continuous clock.
        var clock: Double
        /// How far the wave swings, 0 to 1.
        var amplitude: Double
        /// Opacity of the stream of faint words, 0 to 1.
        var streamOpacity: Double
        /// How far each fragment has lifted out of the stream into its line, 0 to 1.
        var settle: [Double]
        /// Opacity of the settled lines as a group, 0 to 1.
        var lineOpacity: Double
    }

    static let onAmplitude = 0.3
    static let onStream = 0.4
    static let sweepingAmplitude = 0.55

    /// Which mode the stage is in. The enable moment is only ever started by the switch, never by opening the page.
    static func mode(on: Bool, enableStartedAt: Date?, now: Date) -> Mode {
        guard on else { return .teaser }
        if let start = enableStartedAt, now >= start, now.timeIntervalSince(start) < enableDuration { return .enabling }
        return .on
    }

    /// Seconds between frames: the moment of enabling is smooth, the loop is slow and calm, the on state is nearly still.
    /// Measured at about 3 ms of CPU per frame, so these keep drawing under about 5% of one core.
    static func refreshInterval(mode: Mode, sweeping: Bool) -> TimeInterval {
        switch mode {
        case .enabling: return 1.0 / 30
        case .teaser: return 1.0 / 15
        case .on: return sweeping ? 1.0 / 15 : 1.0 / 10
        }
    }

    /// The frame at `clock` seconds. `since` is the time since the switch was turned on (enabling only).
    /// `sweeping` makes the wave of the on state move a little more; it is never a progress bar.
    static func frame(mode: Mode, clock: Double, since: Double = 0, reduceMotion: Bool, sweeping: Bool = false) -> Frame {
        if reduceMotion { return still(mode: mode) }
        switch mode {
        case .teaser:
            let t = clock.truncatingRemainder(dividingBy: teaserPeriod)
            // Rise one after the other from 3 s, hold, then let go from 11.5 s.
            let settle = (0..<lineCount).map { i in
                ease((t - 3 - 1.1 * Double(i)) / 1.6) * (1 - ease((t - 11.5 - 0.5 * Double(i)) / 1.4))
            }
            let lifted = settle.max() ?? 0
            return Frame(clock: clock, amplitude: 1, streamOpacity: 1 - 0.65 * lifted, settle: settle, lineOpacity: 1)
        case .enabling:
            let gather = ease(since / 1.0)
            let resolve = ease((since - 1.15) / 0.65)
            let settle = (0..<lineCount).map { i in ease((since - 0.2 - 0.22 * Double(i)) / 0.7) }
            let lifted = settle.max() ?? 0
            let toward = 1 - 0.4 * gather * (1 - resolve)
            return Frame(clock: clock,
                         amplitude: lerp(1, onAmplitude, resolve) * (1 - 0.3 * gather * (1 - resolve)),
                         streamOpacity: lerp((1 - 0.6 * lifted) * toward, onStream, resolve),
                         settle: settle, lineOpacity: 1 - resolve)
        case .on:
            return Frame(clock: clock, amplitude: sweeping ? sweepingAmplitude : onAmplitude, streamOpacity: onStream,
                         settle: [0, 0, 0], lineOpacity: 0)
        }
    }

    /// The composed still of Reduce Motion: the wave held at one phase, and in the teaser the three lines settled.
    /// Turning the switch on shows the on still; the page cross-fades to it and nothing else moves.
    static func still(mode: Mode) -> Frame {
        switch mode {
        case .teaser:
            return Frame(clock: 6, amplitude: 0.6, streamOpacity: 0.4, settle: [1, 1, 1], lineOpacity: 1)
        case .enabling, .on:
            return Frame(clock: 6, amplitude: onAmplitude, streamOpacity: onStream, settle: [0, 0, 0], lineOpacity: 0)
        }
    }

    private static func ease(_ x: Double) -> Double { MotionEasing.softOut.value(at: max(0, min(1, x))) }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    // MARK: sample text (invented, no real names)

    struct Fragment: Equatable {
        var tag: String
        var text: String
    }

    static let fragments = [
        Fragment(tag: "To-do", text: "Send the budget draft by Friday"),
        Fragment(tag: "Decision", text: "We keep the weekly review on Mondays"),
        Fragment(tag: "Fact", text: "The venue holds 120 people"),
    ]

    /// The faint speech that flows past, one row per line of the stream.
    static let streamRows = [
        "so I think we should send the budget draft by Friday and then the venue holds about 120 people which is fine",
        "okay and for the review we keep it on Mondays I was going to say the same thing about the schedule",
        "remind me to book the room and we agreed that the first week is for the draft only right",
        "yes the numbers look better than last quarter so let us go with the smaller plan and see how it holds",
        "can you share the notes after the call I will add them to the folder and we can look again on Thursday",
    ]
}
