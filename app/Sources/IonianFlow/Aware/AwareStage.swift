import SwiftUI

/// Timing and phases of the Aware stage (F3.13 to F3.14): a soft wave of faint words, and a few fragments that
/// lift out of it and settle as crisp lines. Pure: time in, what to draw out. Motion is slow and continuous
/// (MOT-01), eased with `motion.easing.soft-out`, and Reduce Motion selects one composed still frame (MOT-04).
enum AwareStage {
    enum Mode: Equatable {
        /// Aware is off: the fragments settle once, slowly, then the stage rests as a composed still.
        case teaser
        /// The switch was just turned on: the lines let go and the stage settles into its quiet on state.
        case enabling
        /// Aware is on: fully still. Only a running sweep moves the wave, gently.
        case on
    }

    static let lineCount = 3
    /// The teaser plays once per app launch and takes about 3.5 seconds.
    static let teaserDuration: TimeInterval = 3.5
    static let enableDuration: TimeInterval = 1.5
    /// Radians per second of the wave while it moves: one slow swell, about 18 s per crest.
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

    // The stream stays low in contrast: it is the background, the lines are the point.
    static let restClock = 6.0
    static let restAmplitude = 0.5
    static let restStream = 0.35
    static let onAmplitude = 0.25
    static let onStream = 0.3
    static let sweepingAmplitude = 0.45
    /// How fast the wave moves while a sweep runs, relative to a second of the clock.
    static let sweepPace = 0.6

    /// Which mode the stage is in. The enable moment is only ever started by the switch, never by opening the page.
    static func mode(on: Bool, enableStartedAt: Date?, now: Date) -> Mode {
        guard on else { return .teaser }
        if let start = enableStartedAt, now >= start, now.timeIntervalSince(start) < enableDuration { return .enabling }
        return .on
    }

    /// Whether anything moves at this instant. When it is false no timeline runs at all, so a resting stage costs nothing.
    static func animates(mode: Mode, since: Double, sweeping: Bool) -> Bool {
        switch mode {
        case .teaser: return since < teaserDuration
        case .enabling: return since < enableDuration
        case .on: return sweeping
        }
    }

    /// Seconds between frames while something moves.
    static func refreshInterval(mode: Mode, sweeping: Bool) -> TimeInterval {
        switch mode {
        case .enabling: return 1.0 / 30
        case .teaser: return 1.0 / 20
        case .on: return 1.0 / 12
        }
    }

    /// The frame `since` seconds into the mode: since the page showed the teaser, since the switch was turned on,
    /// or since the sweep began. A sweep is the only thing that moves the on state, and it shows no progress.
    static func frame(mode: Mode, since: Double, reduceMotion: Bool, sweeping: Bool = false) -> Frame {
        if reduceMotion { return still(mode: mode) }
        switch mode {
        case .teaser:
            guard since < teaserDuration else { return still(mode: .teaser) }
            // The lines rise one after the other, slowly; the wave drifts a little on the way to its rest.
            let settle = (0..<lineCount).map { i in ease((since - 0.3 - 0.9 * Double(i)) / 1.4) }
            let lifted = settle.reduce(0, +) / Double(lineCount)
            return Frame(clock: restClock - (teaserDuration - max(0, since)) * 0.5,
                         amplitude: lerp(0.8, restAmplitude, lifted), streamOpacity: lerp(0.6, restStream, lifted),
                         settle: settle, lineOpacity: 1)
        case .enabling:
            guard since < enableDuration else { return still(mode: .on) }
            // From the resting teaser to the quiet on state: the lines let go, nothing travels.
            let resolve = ease((since - 0.6) / 0.9)
            return Frame(clock: restClock, amplitude: lerp(restAmplitude, onAmplitude, resolve),
                         streamOpacity: lerp(restStream, onStream, resolve), settle: [1, 1, 1], lineOpacity: 1 - resolve)
        case .on:
            guard sweeping else { return still(mode: .on) }
            let r = ease(since / 1.5)
            return Frame(clock: restClock + max(0, since) * sweepPace, amplitude: lerp(onAmplitude, sweepingAmplitude, r),
                         streamOpacity: onStream, settle: [0, 0, 0], lineOpacity: 0)
        }
    }

    /// The composed still: also the Reduce Motion frame. The teaser rests with its three lines settled; the on state
    /// is the wave alone, held at one phase.
    static func still(mode: Mode) -> Frame {
        switch mode {
        case .teaser:
            return Frame(clock: restClock, amplitude: restAmplitude, streamOpacity: restStream, settle: [1, 1, 1], lineOpacity: 1)
        case .enabling, .on:
            return Frame(clock: restClock, amplitude: onAmplitude, streamOpacity: onStream, settle: [0, 0, 0], lineOpacity: 0)
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

/// The teaser plays at most once per app launch: opening the page again shows the resting frame.
enum AwareStageLaunch {
    nonisolated(unsafe) static var played = false

    /// True the first time only.
    static func claim() -> Bool {
        defer { played = true }
        return !played
    }
}
