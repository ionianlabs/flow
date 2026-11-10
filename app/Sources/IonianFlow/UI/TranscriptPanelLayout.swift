import AppKit

/// Shared measures of the transcript panel.
enum TranscriptLayout {
    static let margin: CGFloat = 12
    /// Size of the mini pill (SC1).
    static let pillSize = CGSize(width: 260, height: 44)
}

/// Full side panel or the small pill.
enum TranscriptPanelMode: String { case full, mini }

enum PillCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Quarter of `visibleFrame` that `point` falls in; x == midX is right, y == midY is bottom (F2.2).
    static func nearest(point: CGPoint, in visibleFrame: CGRect) -> PillCorner {
        let right = point.x >= visibleFrame.midX
        let top = point.y > visibleFrame.midY
        switch (top, right) {
        case (true, false): return .topLeft
        case (true, true): return .topRight
        case (false, false): return .bottomLeft
        case (false, true): return .bottomRight
        }
    }

    /// Frame of a `size` box in this corner of `visibleFrame`, inset by `margin` (F1.1, F2.1).
    func frame(size: CGSize, in visibleFrame: CGRect, margin: CGFloat = TranscriptLayout.margin) -> CGRect {
        let left = self == .topLeft || self == .bottomLeft
        let top = self == .topLeft || self == .topRight
        let x = left ? visibleFrame.minX + margin : visibleFrame.maxX - size.width - margin
        let y = top ? visibleFrame.maxY - size.height - margin : visibleFrame.minY + margin
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

enum PillClick {
    /// Largest press-to-release distance still counted as a click (F1.4a).
    static let slop: CGFloat = 4
    static func isClick(down: CGPoint, up: CGPoint) -> Bool {
        hypot(up.x - down.x, up.y - down.y) <= slop
    }
}

/// One screen as the layout sees it; built from NSScreen by the wiring code.
struct ScreenRect: Equatable { let id: UInt32; let frame: CGRect; let visibleFrame: CGRect }

enum PillPlacement {
    /// Screen containing the dropped pill's centre, else the pointer's, else main (F2.1, F2.3).
    static func dropScreen(center: CGPoint, pointer: CGPoint, screens: [ScreenRect], main: ScreenRect?) -> ScreenRect? {
        screens.first { $0.frame.contains(center) } ?? targetScreen(pointer: pointer, screens: screens, main: main)
    }

    /// Screen containing the pointer, else main.
    static func targetScreen(pointer: CGPoint, screens: [ScreenRect], main: ScreenRect?) -> ScreenRect? {
        screens.first { $0.frame.contains(pointer) } ?? main
    }

    /// After a screen change: the pill's own screen (new visibleFrame) if still there, else the target screen (F2.6).
    static func screenAfterChange(ownID: UInt32, pointer: CGPoint, screens: [ScreenRect], main: ScreenRect?) -> ScreenRect? {
        screens.first { $0.id == ownID } ?? targetScreen(pointer: pointer, screens: screens, main: main)
    }
}

/// Remembered mode and pill corner (F2.4, F3.6).
struct TranscriptPanelPrefs {
    static let modeKey = "transcriptPanelMode"
    static let cornerKey = "transcriptPillCorner"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Absent or invalid reads as full.
    var mode: TranscriptPanelMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(TranscriptPanelMode.init(rawValue:)) ?? .full }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    /// Absent or invalid reads as bottom right.
    var corner: PillCorner {
        get { defaults.string(forKey: Self.cornerKey).flatMap(PillCorner.init(rawValue:)) ?? .bottomRight }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.cornerKey) }
    }
}

/// Consent line shown for 5 s after a start in mini mode; time comes in as `now` (F3.1, F3.3, F3.4).
struct ConsentReminder {
    static let duration: TimeInterval = 5
    private(set) var startedAt: Date?
    mutating func start(at: Date) { startedAt = at }
    mutating func cancel() { startedAt = nil }
    func isShowing(at now: Date) -> Bool {
        guard let s = startedAt else { return false }
        return s <= now && now < s.addingTimeInterval(Self.duration)
    }
    /// When the line should disappear; nil when not running.
    func endsAt() -> Date? { startedAt?.addingTimeInterval(Self.duration) }
}

extension TranscriptPanel {
    /// Full panel frame: right edge, full height, remembered width clamped to [min, half the screen] (F1.4).
    static func fullFrame(savedWidth: CGFloat, in visibleFrame: CGRect) -> CGRect {
        let m = TranscriptLayout.margin
        let wanted = savedWidth > 0 ? savedWidth : WindowLayout.transcript.width
        let width = min(max(wanted, WindowLayout.transcriptMin.width), visibleFrame.width / 2)
        return CGRect(x: visibleFrame.maxX - width - m, y: visibleFrame.minY + m,
                      width: width, height: visibleFrame.height - 2 * m)
    }

    /// Mode-change animation length: none under Reduce Motion (F1.9, SC2).
    static func modeChangeDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : MotionDuration.hover
    }

    /// Mini is not resizable (F1.11).
    static func styleMask(for mode: TranscriptPanelMode) -> NSWindow.StyleMask {
        mode == .full ? [.nonactivatingPanel, .borderless, .resizable] : [.nonactivatingPanel, .borderless]
    }

    static func minSize(for mode: TranscriptPanelMode) -> CGSize {
        mode == .full ? WindowLayout.transcriptMin : TranscriptLayout.pillSize
    }
}
