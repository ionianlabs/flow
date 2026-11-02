import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    @Published var visible = false
    @Published private(set) var text = ""
    /// Number of trailing characters of `text` that are still fading in.
    @Published private(set) var freshCount = 0
    /// Bumped when a new batch of characters starts fading in; restarts the reveal animation.
    @Published private(set) var generation = 0
    @Published var lang: String?
    @Published var level: Float = 0
    @Published var finishing = false
    /// Hands-free mode (double-tap): recording continues until the next press.
    @Published var locked = false
    /// When the pill appeared, for its timer.
    var startedAt = Date()

    private var batchStarted = Date.distantPast
    private static let maxChars = 320
    private static let maxLines = 4  // logical lines; wrapping can add more on screen

    func reset() {
        startedAt = Date()
        text = ""
        freshCount = 0
        lang = nil
        level = 0
        finishing = false
        locked = false
    }

    /// Partials arrive once per 320 ms chunk, as several tokens a few ms apart. Tokens within one
    /// burst join the same reveal; a new burst starts a new one.
    func update(_ full: String) {
        let new = Self.tail(full)
        guard new != text else { return }
        let common = new.commonPrefix(with: text).count
        let added = new.count - common
        if Date().timeIntervalSince(batchStarted) < 0.15 {
            freshCount = min(new.count, freshCount + added)
        } else {
            freshCount = added
            generation += 1
            batchStarted = Date()
        }
        text = new
    }

    /// Keep the HUD small: show the most recent lines and words.
    private static func tail(_ full: String) -> String {
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        let s = lines.count > maxLines ? lines.suffix(maxLines).joined(separator: "\n") : full
        guard s.count > maxChars else { return s }
        let cut = s.suffix(maxChars)
        let word = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[word...]
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

/// `radius.pill` for one line, `radius.lg` from two lines up (MAC-18). The pill radius is clamped to half the height.
struct ReadingShape: InsettableShape {
    var multiline: Bool
    private var inset: CGFloat = 0

    init(multiline: Bool) { self.multiline = multiline }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = multiline ? Radius.lg : min(Radius.pill, r.height / 2)
        return Path(roundedRect: r, cornerSize: CGSize(width: radius, height: radius), style: multiline ? .continuous : .circular)
    }

    func inset(by amount: CGFloat) -> ReadingShape {
        var s = self
        s.inset += amount
        return s
    }
}

/// The listening pill made real (MAC-12): glass, one line of live text, a mono timer, the wave, and the
/// language in its own glass circle. Empty it stays compact; once text arrives it jumps once to a fixed
/// reading width (MAC-18).
struct OverlayView: View {
    static let maxLines = 8
    private static let minHeight: CGFloat = 52
    /// Pill plus language circle, once text appears.
    static let readingWidth: CGFloat = 640
    private static let langSize: CGFloat = 42
    private static let langGap = Space.s2
    /// Taller than 1.5 lines of `type.small` means two lines or more.
    private static let multilineHeight = IonianType.small.size * IonianType.small.lineHeight * 1.5
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textHeight: CGFloat = 0

    private var multiline: Bool { !model.text.isEmpty && textHeight > Self.multilineHeight }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.visible { row.transition(.opacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Space.s4)
    }

    private var row: some View {
        HStack(spacing: Self.langGap) {
            pill
            if let lang = model.lang { language(lang) }
        }
        .frame(maxWidth: model.text.isEmpty ? nil : Self.readingWidth)
        .fixedSize(horizontal: model.text.isEmpty, vertical: false)
    }

    private var pill: some View {
        HStack(spacing: Space.s4) {
            transcript
                .frame(maxWidth: model.text.isEmpty ? nil : .infinity, alignment: .leading)
            meta
            Wave(level: model.level, active: !model.finishing)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s3)
        .frame(minHeight: Self.minHeight)
        .ionianGlass(in: ReadingShape(multiline: multiline))
        .animation(nil, value: multiline)
    }

    /// The two-letter language in its own glass circle, next to the pill.
    private func language(_ code: String) -> some View {
        Text(String(code.prefix(2)))
            .font(.ionian(IonianType.code, size: IonianType.body.size))
            .kerning(IonianType.label.tracking * IonianType.body.size)
            .textCase(.uppercase)
            .foregroundStyle(Color.accent)
            .frame(width: Self.langSize, height: Self.langSize)
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

    @ViewBuilder private var transcript: some View {
        if model.text.isEmpty {
            Text(model.finishing ? "Done" : "Listening")
                .ionianText(IonianType.small, weight: 500)
                .foregroundStyle(Color.ink)
        } else {
            let split = model.text.index(model.text.endIndex, offsetBy: -model.freshCount)
            let text = (Text(verbatim: String(model.text[..<split]))
                + Text(verbatim: String(model.text[split...])).customAttribute(Fresh()))
                .ionianText(IonianType.small)
                .foregroundStyle(Color.ink)
                .lineLimit(Self.maxLines)
                .truncationMode(.head)  // if it still overflows, drop the oldest text
                .multilineTextAlignment(.leading)
                .contentTransition(.identity)  // no crossfade on re-wrap; RevealRenderer handles new glyphs
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { textHeight = $0 }
            if reduceMotion {
                text
            } else {
                text.keyframeAnimator(initialValue: 1.0, trigger: model.generation) { view, progress in
                    view.textRenderer(RevealRenderer(progress: progress))
                } keyframes: { _ in
                    MoveKeyframe(0.0)
                    CubicKeyframe(1.0, duration: 0.5)
                }
            }
        }
    }
}

// MARK: - Fluid text reveal

private struct Fresh: TextAttribute {}

/// Draws glyphs marked `Fresh` rising in, staggered left to right: opacity and translation only (MOT-05).
private struct RevealRenderer: TextRenderer {
    var progress: Double

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let fresh = layout.flatMap { $0 }.filter { $0[Fresh.self] != nil }.reduce(0) { $0 + $1.count }
        let stagger = fresh > 1 ? min(0.5, 6.0 / Double(fresh)) : 0  // share of the timeline spent staggering
        var i = 0
        for line in layout {
            for run in line {
                guard run[Fresh.self] != nil, progress < 1 else {
                    ctx.draw(run)
                    continue
                }
                for glyph in run {
                    let start = fresh > 1 ? stagger * Double(i) / Double(fresh - 1) : 0
                    let p = max(0, min(1, (progress - start) / (1 - stagger)))
                    var c = ctx
                    c.opacity = p
                    c.translateBy(x: 0, y: (1 - p) * 5)
                    c.draw(glyph)
                    i += 1
                }
            }
        }
    }
}
