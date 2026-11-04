import AppKit
import SwiftUI

/// Sizes of the pill, shared by the model (which wraps the text) and the view (which draws it).
enum OverlayMetrics {
    /// Pill plus language circle, once the pill is open.
    static let readingWidth: CGFloat = 640
    static let langSize: CGFloat = 42
    static let langGap = Space.s2
    static let pillPadding = Space.s6
    static let pillSpacing = Space.s4
    static let waveWidth: CGFloat = 14 * 3 + 13 * 3
    /// The timer's slot; the hands-free hint is wider.
    static func metaWidth(locked: Bool) -> CGFloat { locked ? 100 : 48 }
    /// The pill before anyone speaks: "Listening", the timer and the wave.
    static func compactWidth(locked: Bool) -> CGFloat { locked ? 342 : 290 }
    static let lineHeight = IonianType.small.size * IonianType.small.lineHeight
    static var pillWidth: CGFloat { readingWidth - langGap - langSize }
    /// Room for one line of text. The wrap keeps a few points back for SwiftUI's own measuring.
    static func textWidth(locked: Bool) -> CGFloat {
        pillWidth - 2 * pillPadding - 2 * pillSpacing - metaWidth(locked: locked) - waveWidth - 4
    }
}

/// Measures words in the pill's text face, once per distinct word.
private final class WordMeter {
    private let font = IonianFont.ns(.sans, size: IonianType.small.size, weight: IonianType.small.weight)
    private var cache: [String: CGFloat] = [:]
    private(set) lazy var space: CGFloat = measure(" ")

    func measure(_ s: String) -> CGFloat {
        if let w = cache[s] { return w }
        let w = ceil((s as NSString).size(withAttributes: [.font: font]).width)
        if cache.count > 4000 { cache.removeAll() }
        cache[s] = w
        return w
    }
}

final class OverlayModel: ObservableObject {
    @Published var visible = false
    @Published private(set) var words: [OverlayWord] = []
    /// Whole visual lines as word ranges, wrapped once at the reading width: they do not re-wrap while speaking.
    @Published private(set) var lines: [Range<Int>] = []
    /// The reveal clock has to run until `until`; `id` counts bursts.
    @Published private(set) var reveal = Reveal(id: 0, until: 0)
    /// Someone is talking (the mic level says so, or the first partial is here): the pill opens to reading width.
    @Published private(set) var opened = false
    @Published var lang: String?
    @Published var level: Float = 0 {
        didSet {
            guard !opened else { return }
            gate.feed(level: level, at: now)
            if gate.open { opened = true }
        }
    }
    @Published var finishing = false
    /// Hands-free mode (double-tap): recording continues until the next press.
    @Published var locked = false {
        didSet { if locked != oldValue { rewrap(from: 0) } }
    }
    /// When the pill appeared, for its timer and the reveal clock.
    var startedAt = Date()

    struct Reveal: Equatable { var id: Int; var until: Double }

    private var stream = OverlayStream()
    private var gate = VoiceGate()
    private let meter = WordMeter()

    var text: String { stream.text }
    /// Seconds since the pill appeared: the clock the words' start times are on.
    var now: Double { Date().timeIntervalSince(startedAt) }

    func reset() {
        startedAt = Date()
        stream.reset()
        gate.reset()
        words = []
        lines = []
        reveal = Reveal(id: 0, until: 0)
        opened = false
        lang = nil
        level = 0
        finishing = false
        locked = false
    }

    /// Partials arrive once per 560 ms chunk, as several tokens a few ms apart. The words that are new, or
    /// that the decoder rewrote, get a reveal start spread over the expected time to the next burst.
    func update(_ full: String) {
        guard let until = stream.update(full, now: now) else { return }
        words = stream.words
        rewrap(from: stream.changedFrom)
        if !opened { opened = true }
        reveal = Reveal(id: reveal.id + 1, until: until)
    }

    private func rewrap(from changed: Int) {
        let widths = stream.words.map { meter.measure($0.text) }
        stream.rewrap(changedFrom: changed, widths: widths, space: meter.space, width: OverlayMetrics.textWidth(locked: locked))
        lines = stream.lines
    }
}

/// Floating, non-activating HUD at the bottom of the screen; never takes focus or mouse events.
final class OverlayPanel {
    let model = OverlayModel()
    private let panel: NSPanel
    private static let size = WindowLayout.pill

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the glass draws its own
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show() {
        model.reset()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.minY + 24))
        }
        panel.orderFrontRegardless()
        withAnimation(Self.fade) { model.visible = true }
    }

    func hide() {
        withAnimation(Self.fade) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + MotionDuration.hover + 0.05) { [self] in
            if !model.visible { panel.orderOut(nil) }
        }
    }

    /// Opacity only, no scale or bounce; nothing at all under Reduce Motion.
    private static var fade: Animation? { reduceMotionEnabled ? nil : .easeInOut(duration: MotionDuration.hover) }
}

/// `radius.pill` for one line, `radius.lg` from two lines up (MAC-18), and anything between while it eases
/// from one to the other. The pill radius is clamped to half the height.
struct ReadingShape: InsettableShape {
    /// 0 is the pill, 1 the card.
    var round: CGFloat
    private var inset: CGFloat = 0

    init(round: CGFloat) { self.round = round }

    var animatableData: CGFloat {
        get { round }
        set { round = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let pill = min(Radius.pill, r.height / 2)
        let radius = pill + (Radius.lg - pill) * round
        return Path(roundedRect: r, cornerSize: CGSize(width: radius, height: radius), style: round > 0 ? .continuous : .circular)
    }

    func inset(by amount: CGFloat) -> ReadingShape {
        var s = self
        s.inset += amount
        return s
    }
}

/// The listening pill made real (MAC-12): glass, live text, a mono timer, the wave, and the language in its
/// own glass circle. It opens to the reading width as soon as a voice is heard, before the first words exist
/// (MAC-18); the text is a window of two whole lines at the bottom, and a third line scrolls the first one out.
struct OverlayView: View {
    private static let minHeight: CGFloat = 52
    /// Where lines fade out above the window, inside the pill's own padding.
    private static let band = OverlayMetrics.lineHeight / 2
    /// `motion.easing.soft-out`, `motion.duration.sign`: the pill opens and the lines scroll with it, no overshoot.
    private static let ease = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: MotionDuration.sign)
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts up while words are revealing, so the text redraws; the words read the clock themselves.
    @State private var phase = 0.0
    @State private var pulse = false

    private var hasText: Bool { !model.words.isEmpty }
    /// Open to the reading width. Stopping without a word goes back to the compact "Done".
    private var open: Bool { (model.opened || hasText) && !(model.finishing && !hasText) }
    private var rows: Int { min(OverlayStream.visibleLines, max(1, model.lines.count)) }
    private var layoutKey: [Int] { [open ? 1 : 0, model.lines.count] }
    private var move: Animation? { reduceMotion ? nil : Self.ease }
    private var fade: Animation? { reduceMotion ? nil : .easeInOut(duration: MotionDuration.hover) }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.visible { row.transition(.opacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Space.s4)
    }

    private var row: some View {
        ZStack(alignment: .trailing) {
            pill
                .frame(width: open ? OverlayMetrics.pillWidth : OverlayMetrics.compactWidth(locked: model.locked))
                .frame(maxWidth: .infinity, alignment: .leading)
            if open, let lang = model.lang { language(lang) }
        }
        .frame(width: open ? OverlayMetrics.readingWidth : OverlayMetrics.compactWidth(locked: model.locked))
        .animation(move, value: layoutKey)
    }

    private var pill: some View {
        HStack(spacing: OverlayMetrics.pillSpacing) {
            transcript
                .frame(maxWidth: .infinity, alignment: .leading)
            meta
                .frame(width: OverlayMetrics.metaWidth(locked: model.locked), alignment: .trailing)
            Wave(level: model.level, active: !model.finishing)
        }
        .padding(.horizontal, OverlayMetrics.pillPadding)
        .padding(.vertical, Space.s3)
        .frame(minHeight: Self.minHeight)
        .ionianGlass(in: ReadingShape(round: model.lines.count >= 2 ? 1 : 0))
    }

    /// The two-letter language in its own glass circle, next to the pill.
    private func language(_ code: String) -> some View {
        Text(String(code.prefix(2)))
            .font(.ionian(IonianType.code, size: IonianType.body.size))
            .kerning(IonianType.label.tracking * IonianType.body.size)
            .textCase(.uppercase)
            .foregroundStyle(Color.accent)
            .frame(width: OverlayMetrics.langSize, height: OverlayMetrics.langSize)
            .ionianGlass(in: Circle())
            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel("Language \(code.prefix(2))")
    }

    /// `00:07`, or the hands-free hint `⌥ to finish`, next to the wave.
    private var meta: some View {
        TimelineView(.periodic(from: model.startedAt, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(model.startedAt)))
            let line = model.locked && !model.finishing
                ? "\(Settings.dictationKey.keyLabel) to finish"
                : String(format: "%02d:%02d", seconds / 60, seconds % 60)
            MonoLabel(line, color: Color.muted).lineLimit(1).fixedSize()
                .help(model.locked ? "Hands-free: press \(Settings.dictationKey.name) to finish" : "")
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        let waiting = !hasText && !model.opened || model.finishing && !hasText
        let listening = !hasText && model.opened && !model.finishing
        return ZStack(alignment: .leading) {
            Text(model.finishing ? "Done" : "Listening")
                .ionianText(IonianType.small, weight: 500)
                .foregroundStyle(Color.ink)
                .opacity(waiting ? 1 : 0)
            caret.opacity(listening ? 1 : 0)
            if hasText { window }
        }
        .animation(fade, value: waiting)
        .animation(fade, value: listening)
        .onChange(of: model.reveal) { _, r in
            guard !reduceMotion else { return }
            // Linear on purpose: the clock the words read runs at the pace of time.
            withAnimation(.linear(duration: max(0.05, r.until - model.now + 0.06))) { phase += 1 }
        }
    }

    /// A quiet text caret while the pill is open and the first words are on their way.
    private var caret: some View {
        Capsule()
            .fill(Color.muted)
            .frame(width: 2, height: IonianType.small.size)
            .opacity(reduceMotion ? 0.5 : pulse ? 0.25 : 0.7)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: MotionDuration.caret).repeatForever(autoreverses: true)) { pulse = true }
            }
    }

    /// Two lines tall at most, newest text on the last line. A new line enters from below while the rest
    /// moves up; the top line leaves through a soft edge inside the pill's padding. Opacity and translation only.
    private var window: some View {
        let h = OverlayMetrics.lineHeight
        let count = model.lines.count
        let top = max(0, count - OverlayStream.visibleLines)
        let epoch = model.startedAt, now = model.now, words = model.words
        return ZStack(alignment: .topLeading) {
            ForEach(Array(OverlayStream.window(lineCount: count)), id: \.self) { i in
                let range = model.lines[i]
                OverlayLine(words: words[range.clamped(to: 0..<words.count)], epoch: epoch, now: now, phase: phase, animated: !reduceMotion)
                    .offset(y: CGFloat(i - top) * h + Self.band)
                    .opacity(i < top ? 0 : 1)
                    .transition(reduceMotion ? .identity : .asymmetric(insertion: .offset(y: h), removal: .identity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CGFloat(rows) * h + Self.band, alignment: .topLeading)
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.band)
                Rectangle()
            }
        }
        .padding(.top, -Self.band)
        .frame(height: CGFloat(rows) * h, alignment: .top)
    }
}

// MARK: - Line and word reveal

private struct Fresh: TextAttribute { var start: Double }

/// One visual line of the window. Words whose reveal has not finished carry their start time; the rest is
/// plain text, so a line that is done costs nothing to draw.
private struct OverlayLine: View {
    let words: ArraySlice<OverlayWord>
    let epoch: Date
    let now: Double
    let phase: Double
    let animated: Bool

    var body: some View {
        let text = composed
            .ionianText(IonianType.small)
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .fixedSize()
            .frame(height: OverlayMetrics.lineHeight, alignment: .leading)
        if animated {
            text.textRenderer(RevealRenderer(phase: phase, epoch: epoch))
        } else {
            text
        }
    }

    private var composed: Text {
        var out = Text(verbatim: "")
        var settled = ""
        for (n, w) in words.enumerated() {
            let s = n < words.count - 1 ? w.text + " " : w.text
            if animated, w.start + OverlayStream.wordFade > now - 0.1 {
                if !settled.isEmpty { out = out + Text(verbatim: settled); settled = "" }
                out = out + Text(verbatim: s).customAttribute(Fresh(start: w.start))
            } else {
                settled += s
            }
        }
        return settled.isEmpty ? out : out + Text(verbatim: settled)
    }
}

/// Draws each fresh word rising in on its own start time: opacity and translation only (MOT-05). The start
/// times are on the model's clock; the clock is read at every draw, `phase` only asks for the draws.
private struct RevealRenderer: TextRenderer {
    var phase: Double
    let epoch: Date
    private static let softOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.7), endControlPoint: UnitPoint(x: 0.2, y: 1))

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let clock = Date().timeIntervalSince(epoch)
        for line in layout {
            for run in line {
                guard let fresh = run[Fresh.self] else {
                    ctx.draw(run)
                    continue
                }
                let p = Self.softOut.value(at: max(0, min(1, (clock - fresh.start) / OverlayStream.wordFade)))
                guard p > 0 else { continue }
                var c = ctx
                c.opacity = p
                c.translateBy(x: 0, y: (1 - p) * 5)
                c.draw(run)
            }
        }
    }
}
