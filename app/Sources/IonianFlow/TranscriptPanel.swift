import AppKit
import SwiftUI

/// Side panel for transcription mode: full height on the right edge of the screen with the mouse,
/// resizable from its edges (the width is remembered). It never activates Ionian Flow (the meeting
/// app keeps focus) but takes clicks and scrolling.
final class TranscriptPanel {
    var onStop: () -> Void = {}
    private let model: TranscriptModel
    private let panel: NSPanel
    private static let widthKey = "transcriptPanelWidth"
    private static let margin: CGFloat = 12

    init(model: TranscriptModel) {
        self.model = model
        panel = ClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: WindowLayout.transcript.width, height: WindowLayout.transcript.height),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the glass draws its own
        let host = NSHostingView(rootView: TranscriptView(
            model: model,
            onStop: { [weak self] in self?.onStop() },
            onClose: { [weak self] in self?.hide() }
        ))
        host.sizingOptions = []
        panel.contentView = host
        panel.minSize = WindowLayout.transcriptMin
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { [panel] _ in
            UserDefaults.standard.set(Double(panel.frame.width), forKey: Self.widthKey)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let saved = CGFloat(UserDefaults.standard.double(forKey: Self.widthKey))
            let width = min(max(saved > 0 ? saved : WindowLayout.transcript.width, panel.minSize.width), f.width / 2)
            panel.setFrame(NSRect(x: f.maxX - width - Self.margin, y: f.minY + Self.margin,
                                  width: width, height: f.height - 2 * Self.margin), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotionEnabled ? 0 : MotionDuration.hover
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotionEnabled ? 0 : MotionDuration.faq
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }
}

/// Borderless panels refuse key status by default; this one may take it for a click
/// (becomesKeyOnlyIfNeeded keeps it from stealing typing focus).
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct TranscriptView: View {
    @ObservedObject var model: TranscriptModel
    var onStop: () -> Void
    var onClose: () -> Void
    /// Offscreen rendering: no scroll view, so the whole transcript is laid out at once.
    var still = false
    @State private var following = true

    var body: some View {
        panel.ionianGlass(in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private static let pad = Space.s5
    /// Nothing animates under Reduce Motion (MAC-15).
    private static var smooth: Animation? { reduceMotionEnabled ? nil : .smooth(duration: MotionDuration.hover) }
    private static var smoothShort: Animation? { reduceMotionEnabled ? nil : .smooth(duration: MotionDuration.faq) }

    private var panel: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Self.pad)
                .padding(.vertical, Space.s4)
            Hairline()
            transcript
            Hairline()
            footer
                .padding(.horizontal, Self.pad)
                .padding(.top, Space.s3)
                .padding(.bottom, Space.s5)  // clears the rounded corner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Self.smooth, value: model.finishing)
        .animation(Self.smooth, value: model.ended)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if model.ended != nil {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Saved").ionianText(IonianType.card).foregroundStyle(Color.ink)
                    if let url = model.fileURL {
                        MonoLabel(url.deletingPathExtension().lastPathComponent
                                  + (model.summarizing ? " · writing summary" : model.summary != nil ? " · summarized" : ""),
                                  color: Color.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: Space.s2)
                HStack(spacing: Space.s4) {
                    Button("Copy ›") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TranscriptStore.markdown(model), forType: .string)
                    }
                    .help("Copy as Markdown")
                    Button("Folder ↗") {
                        if let url = model.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .help("Show in Finder")
                    Button("Close ›", action: onClose)
                }
                .buttonStyle(.monoLink)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack(alignment: .center, spacing: Space.s3) {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(model.finishing ? "Finishing" : "Transcript").ionianText(IonianType.card).foregroundStyle(Color.ink)
                        TimelineView(.periodic(from: model.started, by: 1)) { t in
                            MonoLabel(Self.elapsed(from: model.started, to: t.date), color: Color.muted)
                        }
                    }
                    Spacer(minLength: Space.s2)
                    Button("Stop", action: onStop)
                        .buttonStyle(.primaryCompact)
                        .disabled(model.finishing)
                        .help("Stop (or \(ShortcutHints.transcribe.lowercasedFirst))")
                }
                HStack(spacing: Space.s6) {
                    meter("You", color: Color.accent, level: model.level)
                        .help("Your microphone")
                    meter("Them", color: Color.muted, level: model.themLevel)
                        .help("What your Mac plays. Flat while nothing plays. If it stays flat while others talk, allow "
                            + "Ionian Flow in System Settings, Privacy & Security, Screen & System Audio Recording.")
                }
            }
        }
    }

    private func meter(_ label: String, color: Color, level: Float) -> some View {
        HStack(spacing: Space.s2) {
            MonoLabel(label, color: color)
            Wave(level: level, bars: 8, active: !model.finishing, scale: 0.5)
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        let blocks = model.blocks(includeLive: true)
        if blocks.isEmpty {
            VStack(spacing: Space.s2) {
                Text(model.ended == nil ? "Listening" : "Nothing was said.")
                    .ionianText(IonianType.small, weight: 500).foregroundStyle(Color.muted)
                MonoLabel("You: your mic · Them: what your Mac plays", color: Color.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if still {
            VStack(alignment: .leading, spacing: Space.s4) {
                Spacer(minLength: 0)
                ForEach(blocks) { BlockView(block: $0) }
            }
            .padding(.horizontal, Self.pad)
            .padding(.vertical, Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        ForEach(blocks) { BlockView(block: $0) }
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .padding(.horizontal, Self.pad)
                    .padding(.vertical, Space.s4)
                }
                .defaultScrollAnchor(.bottom)
                // Follow new text unless the reader scrolled up; scrolling back to the end resumes it.
                // Only the reader's own scrolling decides: right after an automatic scroll the text may
                // already have grown past the end again, which used to stop the following for good.
                .onScrollPhaseChange { old, phase, context in
                    guard phase == .idle, old != .animating else { return }
                    let g = context.geometry
                    following = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 60
                }
                .onChange(of: Self.revision(of: blocks)) {
                    guard following else { return }
                    withAnimation(Self.smooth) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
                // Text that is replaced (final, polished) changes height after the revision did.
                .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, _ in
                    if following { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !following {
                        Button("Latest ↓") {
                            following = true
                            withAnimation(Self.smooth) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        }
                        .buttonStyle(.monoLink)
                        .padding(Space.s4)
                        .transition(.opacity)
                    }
                }
                .animation(Self.smoothShort, value: following)
            }
        }
    }

    private static let end = "end"

    /// Changes whenever text is added or replaced anywhere in the transcript.
    private static func revision(of blocks: [TranscriptModel.Block]) -> Int {
        blocks.reduce(blocks.count) { n, b in b.segments.reduce(n) { $0 &+ $1.text.count &+ $1.id &* 31 } }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            if let notice = model.notice {
                Text(notice).ionianText(IonianType.small).foregroundStyle(Color.ink)
            }
            if model.cancellingEcho && model.ended == nil {
                Text("Removing the speakers' audio from your mic.").ionianText(IonianType.small).foregroundStyle(Color.muted)
            }
            Text("Always get consent when transcribing others.").ionianText(IonianType.small).foregroundStyle(Color.ink)  // muted is too weak over light chrome (COL-04)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: TranscriptModel.Block

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                MonoLabel(block.speaker.rawValue, color: block.speaker == .you ? Color.accent : Color.muted)
                MonoLabel(TranscriptStore.format(block.start, "HH:mm"), color: Color.muted)  // faint is too weak on glass (COL-04)
            }
            // One flowing paragraph; text still being recognized is muted until the final decoder confirms it.
            block.segments.enumerated().reduce(Text("")) { text, item in
                let (i, s) = item
                return text + Text(verbatim: (i > 0 ? " " : "") + s.text)
                    .foregroundStyle(s.stage == .live ? Color.muted : Color.ink)
            }
            .ionianText(IonianType.small)
            .textSelection(.enabled)
            .contentTransition(.interpolate)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The panel in the middle of a meeting, for the offscreen renderer (`--render panel`).
@MainActor func transcriptPreview(empty: Bool = false) -> some View {
    let model = TranscriptModel()
    let now = Date()
    model.started = now.addingTimeInterval(-754)
    model.level = 0.035
    model.themLevel = 0.0005
    let lines: [(Speaker, String, TranscriptSegment.Stage)] = [
        (.you, "Okay, lass uns kurz den Status zum Release durchgehen.", .polished),
        (.them, "Yes, so the pull request is merged and QA starts tomorrow at 9.", .polished),
        (.them, "We still need sign-off from security, though.", .polished),
        (.you, "Gut, dann schieben wir das Deployment auf Donnerstag um 10 Uhr.", .polished),
        (.them, "Works for me. Can you send the summary to the team after the call?", .final),
        (.you, "Mach ich, ich schicke sie euch direkt nach dem", .live),
    ]
    model.segments = empty ? [] : lines.enumerated().map { i, line in
        let start = now.addingTimeInterval(Double(i - lines.count) * 25)
        return TranscriptSegment(id: i + 1, speaker: line.0, start: start, end: start.addingTimeInterval(20),
                                 text: line.1, stage: line.2)
    }
    return TranscriptView(model: model, onStop: {}, onClose: {}, still: true)
}
