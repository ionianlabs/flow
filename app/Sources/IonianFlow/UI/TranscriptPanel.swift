import AppKit
import Combine
import SwiftUI

/// What the panel's root view shows (spec transcript-mini): the mode and the pill's Consent reminder.
final class TranscriptPanelUI: ObservableObject {
    @Published var mode: TranscriptPanelMode = .full
    @Published var reminder = false
}

private struct TranscriptPanelRoot: View {
    @ObservedObject var ui: TranscriptPanelUI
    let model: TranscriptModel
    let onStop: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onExpand: () -> Void
    let onBodyDrag: (CGPoint, CGPoint) -> Void
    let onBodyRelease: (CGPoint, CGPoint) -> Void

    var body: some View {
        switch ui.mode {
        case .full:
            TranscriptView(model: model, onStop: onStop, onClose: onClose, onMinimize: onMinimize)
        case .mini:
            TranscriptPillView(model: model, reminder: ui.reminder, onStop: onStop, onExpand: onExpand,
                               onBodyDrag: onBodyDrag, onBodyRelease: onBodyRelease)
        }
    }
}

/// Side panel for transcription mode: full height on the right edge of the screen with the mouse,
/// resizable from its edges (the width is remembered), or a small pill in a screen corner (mini mode).
/// It never activates Ionian Flow (the meeting app keeps focus) but takes clicks and scrolling, and it
/// is left out of screen sharing.
final class TranscriptPanel {
    var onStop: () -> Void = {}
    private let model: TranscriptModel
    private let panel: NSPanel
    private let prefs: TranscriptPanelPrefs
    private let ui = TranscriptPanelUI()
    private static let widthKey = "transcriptPanelWidth"
    private(set) var mode: TranscriptPanelMode = .full
    private var reminder = ConsentReminder()
    private var reminderTimer: Timer?
    /// The screen the panel was last placed on (F1.1, F2.6).
    private var ownScreen: ScreenRect?
    /// Test seam: where the panel looks for screens when its own is gone.
    var screensProvider: () -> [ScreenRect] = { ScreenRect.all }
    var mainProvider: () -> ScreenRect? = { ScreenRect.main }
    var panelScreenProvider: (() -> ScreenRect?)?
    private var dragStartOrigin: CGPoint?
    private var isDragging = false
    private var observers: [NSObjectProtocol] = []
    private var endedSub: AnyCancellable?

    init(model: TranscriptModel, prefs: TranscriptPanelPrefs = TranscriptPanelPrefs()) {
        self.model = model
        self.prefs = prefs
        panel = ClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: WindowLayout.transcript.width, height: WindowLayout.transcript.height),
            styleMask: TranscriptPanel.styleMask(for: .full),
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
        panel.sharingType = .none  // F4.1: neither mode is visible to people watching a screen share
        let host = NSHostingView(rootView: TranscriptPanelRoot(
            ui: ui, model: model,
            onStop: { [weak self] in self?.handlePillStop() },
            onClose: { [weak self] in self?.hide() },
            onMinimize: { [weak self] in self?.handleMinimize() },
            onExpand: { [weak self] in self?.handleExpand() },
            onBodyDrag: { [weak self] down, current in self?.handlePillDrag(down: down, current: current) },
            onBodyRelease: { [weak self] down, up in self?.handlePillRelease(down: down, up: up) }
        ))
        host.sizingOptions = []
        panel.contentView = host
        panel.minSize = TranscriptPanel.minSize(for: .full)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { [weak self] _ in
            self?.handleLiveResizeEnd()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible, self.mode == .mini else { return }
            self.handleScreenChange(pointer: NSEvent.mouseLocation, screens: ScreenRect.all, main: ScreenRect.main)
        })
        // F1.7: a finished session shows its transcript and summary in the full panel.
        endedSub = model.$ended.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] ended in
            guard let self, ended != nil, self.mode == .mini else { return }
            self.cancelReminder()
            self.setMode(.full, store: false)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        reminderTimer?.invalidate()
    }

    var isVisible: Bool { panel.isVisible }
    var sharingType: NSWindow.SharingType { panel.sharingType }
    var isReminderShowing: Bool { ui.reminder }
    var panelFrame: CGRect { panel.frame }
    var panelStyleMask: NSWindow.StyleMask { panel.styleMask }
    var panelMinSize: CGSize { panel.minSize }

    func show() {
        prepareShow(now: Date(), pointer: NSEvent.mouseLocation, screens: ScreenRect.all, main: ScreenRect.main)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotionEnabled ? 0 : MotionDuration.hover
            panel.animator().alphaValue = 1
        }
    }

    /// Everything `show()` does except ordering the window front: mode, frame, reminder (F3.1, F3.2, F3.6, F2.5).
    func prepareShow(now: Date, pointer: CGPoint, screens: [ScreenRect], main: ScreenRect?) {
        let target = PillPlacement.targetScreen(pointer: pointer, screens: screens, main: main)
        resetDrag()
        mode = prefs.mode
        ui.mode = mode
        panel.styleMask = Self.styleMask(for: mode)
        panel.minSize = Self.minSize(for: mode)
        cancelReminder()
        if let target {
            ownScreen = target
            panel.setFrame(frame(for: mode, on: target), display: true)
        }
        if mode == .mini {
            reminder.start(at: now)
            ui.reminder = reminder.isShowing(at: now)
            if let end = reminder.endsAt() {
                let timer = Timer(timeInterval: max(0, end.timeIntervalSince(now)), repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.ui.reminder = self.reminder.isShowing(at: Date())
                }
                RunLoop.main.add(timer, forMode: .common)  // fires during drag tracking too
                reminderTimer = timer
            }
        }
    }

    func handleHide() { cancelReminder() }

    func hide() {
        handleHide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotionEnabled ? 0 : MotionDuration.faq
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }

    // MARK: Modes

    private func frame(for mode: TranscriptPanelMode, on screen: ScreenRect) -> CGRect {
        switch mode {
        case .mini: return prefs.corner.frame(size: TranscriptLayout.pillSize, in: screen.visibleFrame)
        case .full:
            let saved = CGFloat(prefs.defaults.double(forKey: Self.widthKey))
            return Self.fullFrame(savedWidth: saved, in: screen.visibleFrame)
        }
    }

    /// The screen the panel sits on: the one it was placed on (fresh from the system if it still exists), else where it is.
    private func currentScreen() -> ScreenRect? {
        let all = screensProvider()
        if let own = ownScreen, let fresh = all.first(where: { $0.id == own.id }) { return fresh }
        let current = panelScreenProvider.map { $0() } ?? panel.screen.map(ScreenRect.init)
        return current
            ?? PillPlacement.targetScreen(pointer: NSEvent.mouseLocation, screens: all, main: mainProvider())
    }

    private func resetDrag() { isDragging = false; dragStartOrigin = nil }

    private func cancelReminder() {
        reminder.cancel()
        reminderTimer?.invalidate()
        reminderTimer = nil
        ui.reminder = false
    }

    /// Moves the panel to `frame`, animated unless Reduce Motion is on or nothing is on screen yet.
    private func move(to frame: CGRect, then done: @escaping () -> Void) {
        let duration = panel.isVisible ? Self.modeChangeDuration(reduceMotion: reduceMotionEnabled) : 0
        if duration == 0 {
            panel.setFrame(frame, display: true)
            done()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: done)
        }
    }

    func setMode(_ new: TranscriptPanelMode, store: Bool = true) {
        let screen = currentScreen()
        resetDrag()
        mode = new
        ui.mode = new
        if new == .mini { panel.minSize = Self.minSize(for: .mini) }  // before the frame shrinks
        panel.styleMask = Self.styleMask(for: new)
        let restoreMin: () -> Void = { [weak self] in self?.finishGrow() }
        if let screen {
            ownScreen = screen
            move(to: frame(for: new, on: screen), then: restoreMin)
        } else {
            restoreMin()
        }
        if store { prefs.mode = new }
    }

    /// The remembered width is only ever written in full mode (F1.11).
    /// Completion of the grow animation; a late one must not undo a minimize in between.
    func finishGrow() { if mode == .full { panel.minSize = Self.minSize(for: .full) } }

    func handleLiveResizeEnd() {
        guard mode == .full else { return }
        prefs.defaults.set(Double(panel.frame.width), forKey: Self.widthKey)
    }

    func handleMinimize() { setMode(.mini) }  // F1.1, F3.5: no reminder

    func handleExpand() {  // F1.4, F3.3
        cancelReminder()
        setMode(.full)
    }

    func handlePillStop() { onStop() }  // F1.5: no mode change

    func handlePillDrag(down: CGPoint, current: CGPoint) {
        if dragStartOrigin == nil { dragStartOrigin = panel.frame.origin }
        guard let start = dragStartOrigin, !PillClick.isClick(down: down, up: current) || isDragging else { return }
        isDragging = true
        panel.setFrameOrigin(CGPoint(x: start.x + current.x - down.x, y: start.y + current.y - down.y))
    }

    /// A click on the body expands; the end of a drag snaps to the nearest corner (F1.4a, F2.1 to F2.3).
    func handlePillRelease(down: CGPoint, up: CGPoint, pointer: CGPoint = NSEvent.mouseLocation,
                           screens: [ScreenRect] = ScreenRect.all, main: ScreenRect? = ScreenRect.main) {
        defer { resetDrag() }
        if model.finishing && !isDragging { return }  // a stray click while finishing must not expand
        if !isDragging && PillClick.isClick(down: down, up: up) {
            handleExpand()
            return
        }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = PillPlacement.dropScreen(center: center, pointer: pointer, screens: screens, main: main) else { return }
        let corner = PillCorner.nearest(point: center, in: screen.visibleFrame)
        prefs.corner = corner
        ownScreen = screen
        move(to: corner.frame(size: TranscriptLayout.pillSize, in: screen.visibleFrame), then: {})
    }

    /// F2.6: stay on the own screen at the stored corner; only a removed screen sends the pill to the target screen.
    func handleScreenChange(pointer: CGPoint, screens: [ScreenRect], main: ScreenRect?) {
        guard mode == .mini, let own = ownScreen,
              let screen = PillPlacement.screenAfterChange(ownID: own.id, pointer: pointer, screens: screens, main: main) else { return }
        ownScreen = screen
        panel.setFrame(prefs.corner.frame(size: TranscriptLayout.pillSize, in: screen.visibleFrame), display: true)
    }
}

extension ScreenRect {
    init(_ s: NSScreen) {
        let number = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.init(id: number?.uint32Value ?? 0, frame: s.frame, visibleFrame: s.visibleFrame)
    }
    static var all: [ScreenRect] { NSScreen.screens.map(ScreenRect.init) }
    static var main: ScreenRect? { NSScreen.main.map(ScreenRect.init) }
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
    var onMinimize: () -> Void
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
            HStack(alignment: .center, spacing: Space.s3) {
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
                HStack(spacing: Space.s1) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TranscriptStore.markdown(model), forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy as Markdown")
                    .accessibilityLabel("Copy as Markdown")
                    Button {
                        if let url = model.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .help("Close")
                        .accessibilityLabel("Close")
                }
                .buttonStyle(IconButtonStyle())
                .fixedSize()
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack(alignment: .center, spacing: Space.s3) {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(model.finishing ? "Finishing" : "Transcript").ionianText(IonianType.card).foregroundStyle(Color.ink)
                        TimelineView(.periodic(from: model.started, by: 1)) { t in
                            MonoLabel(TranscriptClock.elapsed(from: model.started, to: t.date), color: Color.muted)
                        }
                    }
                    Spacer(minLength: Space.s2)
                    Button(action: onMinimize) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(IconButtonStyle())
                        .help("Minimize")
                        .accessibilityLabel("Minimize")
                    Button("Stop", action: onStop)
                        .buttonStyle(.primaryCompact)
                        .disabled(model.finishing)
                        .help("Stop (or \(ShortcutHints.transcribe.lowercasedFirst))")
                }
                HStack(spacing: Space.s6) {
                    LevelMeter(label: "You", color: Color.accent, level: model.level, active: !model.finishing)
                        .help("Your microphone")
                    LevelMeter(label: "Them", color: Color.muted, level: model.themLevel, active: !model.finishing)
                        .help("What your Mac plays. Flat while nothing plays. If it stays flat while others talk, allow "
                            + "Ionian Flow in System Settings, Privacy & Security, Screen & System Audio Recording.")
                }
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        let blocks = model.blocks(includeLive: true)
        if blocks.isEmpty {
            VStack(spacing: Space.s2) {
                Text(model.ended == nil ? "Listening" : "Nothing was said.")
                    .ionianText(IonianType.small, weight: 500).foregroundStyle(Color.muted)
                (Text("You").foregroundStyle(Color.accent) + Text(": your mic · Them: what your Mac plays"))
                    .ionianText(IonianType.label).foregroundStyle(Color.muted)
                    .multilineTextAlignment(.center)
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
                        Button {
                            following = true
                            withAnimation(Self.smooth) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(IconButtonStyle())
                        .help("Jump to the latest")
                        .accessibilityLabel("Jump to the latest")
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
            if model.cleanupOff && model.ended == nil {
                Text("Cleanup is off. Segments stay as heard.").ionianText(IonianType.small).foregroundStyle(Color.muted)
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
    private var color: Color { block.speaker == .you ? Color.accent : Color.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                MonoLabel(block.speaker.rawValue, color: color)
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
        .padding(.leading, Space.s3)
        .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 2) }  // the speaker's rule
    }
}

/// A compact square icon button: muted glyph, ink with a faint well on hover. Fixed size, never wraps.
struct IconButtonStyle: ButtonStyle {
    var side: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration, side: side) }

    private struct Label: View {
        let configuration: Configuration
        let side: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering || configuration.isPressed ? Color.ink : Color.muted)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Color.codeBg : .clear))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The panel in the middle of a meeting, for the offscreen renderer (`--render panel`).
@MainActor func transcriptPreview(empty: Bool = false, ended: Bool = false) -> some View {
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
    if ended {
        model.ended = now
        model.fileURL = URL(fileURLWithPath: "/tmp/2026-11-02 Release sync.md")
    }
    return TranscriptView(model: model, onStop: {}, onClose: {}, onMinimize: {}, still: true)
}
