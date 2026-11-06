import AppKit
import Combine
import SwiftUI

/// Draws one `InstinctStage.Frame`: hairline waves, faint speech riding them, and three crisp lines that settle
/// out of it, each tagged. Tokens only; opacity and translation move, nothing else (MOT-05). No chrome here:
/// MAC-13 keeps the one chrome moment of a window for the setup guide, so the stage speaks in ink and hairlines.
enum InstinctStageDrawing {
    static let height: CGFloat = 132
    /// Rows of the stream, as fractions of the height. Rows 1 to 3 are the rows the lines settle into.
    static let rowFractions: [Double] = [0.14, 0.28, 0.5, 0.72, 0.86]
    static let slotRows = [1, 2, 3]
    static let charWidth = 6.2

    static func draw(_ f: InstinctStage.Frame, in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let phase = f.clock * InstinctStage.waveRate

        // Waves: three hairlines.
        for k in 0..<3 {
            var path = Path()
            var x = 0.0
            while x <= w {
                let y = h / 2 + sin(x / w * 2 * .pi * 1.3 + phase + Double(k) * 0.9) * f.amplitude * h * 0.16 * (1 - 0.25 * Double(k))
                x == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                x += 6
            }
            var c = ctx
            c.opacity = (0.9 - 0.25 * Double(k)) * min(1, f.streamOpacity + 0.3)
            c.stroke(path, with: .color(Color.line), lineWidth: 1)
        }

        // Faint speech flowing past, left to right.
        let slotYs = InstinctStageDrawing.slotRows.map { h * rowFractions[$0] }
        for (r, row) in InstinctStage.streamRows.enumerated() {
            let words = row.split(separator: " ").map(String.init)
            let widths = words.map { Double($0.count) * charWidth + 7 }
            let total = widths.reduce(0, +)
            let speed = 12 + 3 * Double(r)
            let shift = (f.clock * speed + Double(r) * 97).truncatingRemainder(dividingBy: total)
            let baseY = h * rowFractions[r]
            var x0 = -shift
            while x0 < w {
                var x = x0
                for (i, word) in words.enumerated() {
                    defer { x += widths[i] }
                    guard x > -widths[i], x < w else { continue }
                    let edge = max(0, min(1, min(x / 70, (w - x) / 70)))
                    let y = baseY + sin(x / w * 2 * .pi * 1.3 + phase + Double(r) * 0.6) * f.amplitude * 8
                    // The row a line settles into gives way to it.
                    var give = 0.0
                    for (s, slotY) in slotYs.enumerated() { give = max(give, f.settle[s] * min(1, f.lineOpacity / 0.15) * min(1, max(0, 1.6 - abs(y - slotY) / 14))) }
                    var c = ctx
                    c.opacity = 0.7 * f.streamOpacity * edge * edge * (1 - give)
                    guard c.opacity > 0.01 else { continue }
                    c.draw(c.resolve(Text(word).font(.ionian(IonianType.caption)).foregroundColor(Color.muted)),
                           at: CGPoint(x: x, y: y), anchor: .leading)
                }
                x0 += total
            }
        }

        // The lines that settle: tag in accent, text in ink.
        let blockW = 86 + 36 * charWidth
        let slotX = max(20, (w - blockW) / 2)
        for (i, fragment) in InstinctStage.fragments.enumerated() {
            let s = f.settle[i] * f.lineOpacity
            guard s > 0.005 else { continue }
            let eased = f.settle[i]
            let from: CGFloat = i == 1 ? -36 : 36
            let x = slotX + from * (1 - eased)
            let y = slotYs[i] + 6 * (1 - eased)
            var c = ctx
            c.opacity = s
            c.draw(c.resolve(Text(fragment.tag.uppercased()).font(.ionian(IonianType.label)).foregroundColor(Color.accent)),
                   at: CGPoint(x: x, y: y), anchor: .leading)
            c.draw(c.resolve(Text(fragment.text).font(.ionian(IonianType.small, size: 14)).foregroundColor(Color.ink)),
                   at: CGPoint(x: x + 86, y: y), anchor: .leading)
        }
    }
}

/// The renders ask for one instant instead of the live clock: seconds into the teaser (use a large number for rest).
private struct StageClockKey: EnvironmentKey { static let defaultValue: Double? = nil }

extension EnvironmentValues {
    /// Set by the offscreen renderer so a page shows the stage at a fixed moment.
    var instinctStageClock: Double? {
        get { self[StageClockKey.self] }
        set { self[StageClockKey.self] = newValue }
    }
}

/// Dates for a timeline that ends: from `start` every `interval` seconds until `duration` has passed. When the
/// last entry is drawn the timeline is finished and nothing runs any more (a resting stage costs nothing).
struct StageSchedule: TimelineSchedule {
    var start: Date
    var duration: TimeInterval
    var interval: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        let end = start.addingTimeInterval(duration)
        var dates: [Date] = []
        var t = max(startDate, start)
        while t < end { dates.append(t); t = t.addingTimeInterval(interval) }
        dates.append(end)
        return dates
    }
}

/// The stage as a card. It moves only while something happens: the teaser once per launch, the enable moment, a
/// running sweep. Otherwise it is one still frame with no timeline. Under Reduce Motion it is always a still frame
/// and the only change is a cross-fade.
struct InstinctStageView: View {
    var on: Bool
    var enableStartedAt: Date?
    var sweeping = false
    /// Replays the teaser from this moment (the preview window); otherwise it plays once per launch.
    var teaserStartedAt: Date?
    /// Draw the Reduce Motion still, as if the system setting were on (renders).
    var forceStill = false
    /// A fixed instant, for renders and previews: mode and seconds into it.
    var fixed: (mode: InstinctStage.Mode, since: Double)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.instinctStageClock) private var renderClock
    @State private var visible = true
    @State private var ownTeaserStart: Date?
    @State private var sweepStart: Date?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        Group {
            if let fixed {
                canvas(InstinctStage.frame(mode: fixed.mode, since: fixed.since, reduceMotion: false, sweeping: sweeping))
            } else if let renderClock {
                canvas(InstinctStage.frame(mode: on ? .on : .teaser, since: renderClock, reduceMotion: false, sweeping: sweeping))
            } else if reduceMotion || forceStill {
                canvas(InstinctStage.still(mode: on ? .on : .teaser)).id(on).transition(.opacity)
            } else {
                live
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: MotionDuration.hover) : nil, value: on)
        .frame(height: InstinctStageDrawing.height)
        .background(shape.fill(Color.surface))
        .overlay(shape.strokeBorder(Color.line))
        .clipShape(shape)
        .accessibilityHidden(true)
        .onAppear {
            visible = Self.windowsVisible()
            if !on, teaserStartedAt == nil, InstinctStageLaunch.claim() { ownTeaserStart = Date() }
            if sweeping, sweepStart == nil { sweepStart = Date() }
        }
        .onDisappear { visible = false }
        .onChange(of: sweeping) { sweepStart = sweeping ? Date() : nil }
        .onReceive(Self.visibilityChanges) { _ in visible = Self.windowsVisible() }
    }

    /// One still canvas, or a timeline that lasts exactly as long as the movement.
    @ViewBuilder private var live: some View {
        let now = Date()
        let mode = InstinctStage.mode(on: on, enableStartedAt: enableStartedAt, now: now)
        if mode == .enabling, let start = enableStartedAt {
            timeline(start: start, duration: InstinctStage.enableDuration, mode: mode)
        } else if mode == .on {
            if sweeping {
                let start = sweepStart ?? now
                TimelineView(.animation(minimumInterval: InstinctStage.refreshInterval(mode: .on, sweeping: true), paused: !visible)) { tl in
                    canvas(InstinctStage.frame(mode: .on, since: tl.date.timeIntervalSince(start), reduceMotion: false, sweeping: true))
                }
            } else {
                canvas(InstinctStage.still(mode: .on))
            }
        } else if let start = teaserStartedAt ?? ownTeaserStart {
            if now.timeIntervalSince(start) < InstinctStage.teaserDuration {
                timeline(start: start, duration: InstinctStage.teaserDuration, mode: .teaser)
            } else {
                canvas(InstinctStage.still(mode: .teaser))
            }
        } else if !InstinctStageLaunch.played {
            canvas(InstinctStage.frame(mode: .teaser, since: 0, reduceMotion: false))   // the first frame, until onAppear starts it
        } else {
            canvas(InstinctStage.still(mode: .teaser))
        }
    }

    private func timeline(start: Date, duration: TimeInterval, mode: InstinctStage.Mode) -> some View {
        TimelineView(StageSchedule(start: start, duration: duration, interval: InstinctStage.refreshInterval(mode: mode, sweeping: false))) { tl in
            canvas(InstinctStage.frame(mode: mode, since: tl.date.timeIntervalSince(start), reduceMotion: false))
        }
    }

    private func canvas(_ frame: InstinctStage.Frame) -> some View {
        Canvas { ctx, size in InstinctStageDrawing.draw(frame, in: &ctx, size: size) }
    }

    private static func windowsVisible() -> Bool {
        !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    private static var visibilityChanges: AnyPublisher<Void, Never> {
        let c = NotificationCenter.default
        return Publishers.MergeMany([
            c.publisher(for: NSWindow.didChangeOcclusionStateNotification),
            c.publisher(for: NSWindow.didMiniaturizeNotification),
            c.publisher(for: NSWindow.didDeminiaturizeNotification),
            c.publisher(for: NSApplication.didHideNotification),
            c.publisher(for: NSApplication.didUnhideNotification),
        ]).map { _ in () }.eraseToAnyPublisher()
    }
}
