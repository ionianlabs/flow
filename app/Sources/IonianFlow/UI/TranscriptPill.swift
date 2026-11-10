import AppKit
import SwiftUI

/// The elapsed-time text of a transcription session, shared by the full header and the pill.
enum TranscriptClock {
    /// `m:ss`, or `h:mm:ss` from one hour on; never negative.
    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A speaker label with its level wave: "You" or "Them" in the header and in the pill.
struct LevelMeter: View {
    let label: String
    let color: Color
    let level: Float
    let active: Bool
    var bars = 8

    var body: some View {
        HStack(spacing: Space.s2) {
            MonoLabel(label, color: color)
            Wave(level: level, bars: bars, active: active, scale: 0.5)
        }
    }
}

/// What the pill shows, without the views (F1, F3). It never holds transcript text (SC4): only the
/// clock, the shortcut hint and flags.
struct TranscriptPillState: Equatable {
    struct Meter: Equatable { let label: String; let color: Color }

    /// The Consent line (F3.1).
    static let consentLine = "Always get consent when transcribing others."

    private let finishing: Bool
    private let reminder: Bool
    private let elapsed: String
    private let shortcutHint: String
    /// F1.8: a notice exists, but its text is not kept.
    let markerShown: Bool

    init(finishing: Bool, notice: String?, reminder: Bool, elapsed: String, shortcutHint: String) {
        self.finishing = finishing
        self.reminder = reminder
        self.elapsed = elapsed
        self.shortcutHint = shortcutHint
        markerShown = !(notice ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Finishing wins over the reminder (F3.7), the reminder over the time (F3.1).
    var label: String { finishing ? "Finishing" : reminder ? Self.consentLine : elapsed }
    /// The reminder replaces the waves and the time (F3.1).
    var showsWaves: Bool { finishing || !reminder }
    var wavesActive: Bool { !finishing }
    var stopEnabled: Bool { !finishing }
    /// F1.3
    func controlsVisible(hovering: Bool) -> Bool { hovering }

    var stopHelp: String { "Stop (or \(shortcutHint.lowercasedFirst))" }
    var stopAccessibilityLabel: String { "Stop transcription" }
    var expandHelp: String { "Show transcript" }
    var expandAccessibilityLabel: String { "Show transcript" }
    /// F1.2
    var meters: [Meter] { [Meter(label: "You", color: Color.accent), Meter(label: "Them", color: Color.muted)] }
}

extension TranscriptPillState {
    @MainActor init(model: TranscriptModel, reminder: Bool, now: Date) {
        self.init(finishing: model.finishing, notice: model.notice, reminder: reminder,
                  elapsed: TranscriptClock.elapsed(from: model.started, to: now), shortcutHint: ShortcutHints.transcribe)
    }
}

/// The 260 x 44 pt mini mode of the transcript panel (F1): both level waves and the time; Stop and
/// expand on hover. The window code decides click versus drag from `onBodyRelease` (`PillClick`).
struct TranscriptPillView: View {
    @ObservedObject var model: TranscriptModel
    var reminder: Bool
    /// Offscreen rendering: no ticking clock, `stillNow` is the instant shown.
    var still = false
    /// Offscreen rendering: draw the hover controls without a pointer.
    var forceControls = false
    var stillNow: Date? = nil
    var onStop: () -> Void = {}
    var onExpand: () -> Void = {}
    /// Screen positions (`NSEvent.mouseLocation`) at mouse down and now / at release.
    var onBodyDrag: (_ down: CGPoint, _ current: CGPoint) -> Void = { _, _ in }
    var onBodyRelease: (_ down: CGPoint, _ up: CGPoint) -> Void = { _, _ in }

    static let size = CGSize(width: 260, height: 44)
    @State private var hovering = false
    @State private var down: CGPoint?

    var body: some View {
        content
            .padding(.horizontal, Space.s3)
            .frame(width: Self.size.width, height: Self.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    // The window moves under the pointer, so the gesture's own coordinates drift.
                    let here = NSEvent.mouseLocation
                    if down == nil { down = here }
                    onBodyDrag(down ?? here, here)
                }
                .onEnded { _ in
                    let here = NSEvent.mouseLocation
                    onBodyRelease(down ?? here, here)
                    down = nil
                })
            .ionianGlass(in: PillShape())
            .onHover { hovering = $0 }
    }

    private func state(at now: Date) -> TranscriptPillState {
        TranscriptPillState(model: model, reminder: reminder, now: now)
    }

    /// Marker, then the waves (or the Consent line), then one trailing slot: the time, which the Stop and
    /// expand controls take over on hover. The time yields to the controls; the waves never do.
    private var content: some View {
        let s = state(at: stillNow ?? model.started)
        let showControls = s.controlsVisible(hovering: hovering || forceControls)
        let reminding = !s.showsWaves
        return HStack(spacing: Space.s2) {
            if s.markerShown {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accent)
                    .accessibilityLabel("Notice")
            }
            if reminding {
                Text(s.label).ionianText(IonianType.small).foregroundStyle(Color.ink)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(s.meters, id: \.label) { m in
                    LevelMeter(label: m.label, color: m.color, level: m.label == "You" ? model.level : model.themLevel,
                               active: s.wavesActive, bars: 5)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            ZStack(alignment: .trailing) {
                if !reminding { timeView.opacity(showControls ? 0 : 1) }
                controls(s, visible: showControls)
            }
            // During the reminder the controls take no room until they show.
            .frame(width: reminding && !showControls ? 0 : nil, alignment: .trailing)
        }
    }

    @ViewBuilder private var timeView: some View {
        if still {
            MonoLabel(state(at: stillNow ?? model.started).label, color: Color.muted).lineLimit(1).fixedSize()
        } else {
            TimelineView(.periodic(from: model.started, by: 1)) { t in
                MonoLabel(state(at: t.date).label, color: Color.muted).lineLimit(1).fixedSize()
            }
        }
    }

    /// Hidden with opacity and hit testing, not removed, so VoiceOver can still reach them (F1.10).
    private func controls(_ s: TranscriptPillState, visible: Bool) -> some View {
        HStack(spacing: Space.s1) {
            Button("Stop", action: onStop)
                .buttonStyle(.primaryCompact)
                .disabled(!s.stopEnabled)
                .help(s.stopHelp)
                .accessibilityLabel(s.stopAccessibilityLabel)
            Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(IconButtonStyle())
                .help(s.expandHelp)
                .accessibilityLabel(s.expandAccessibilityLabel)
        }
        .fixedSize()
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

/// The pill in a known state, for the offscreen renderer (`--render pill`, F5).
@MainActor func pillPreview(finishing: Bool = false, notice: Bool = false, consent: Bool = false) -> some View {
    let model = TranscriptModel()
    let now = Date()
    model.started = now.addingTimeInterval(-754)
    model.level = 0.035
    model.themLevel = 0.0005
    model.finishing = finishing
    if notice { model.notice = "Allow Ionian Flow to record system audio in System Settings." }
    return TranscriptPillView(model: model, reminder: consent, still: true, forceControls: !(notice || consent), stillNow: now)
        .frame(width: 320, height: 100)
}
