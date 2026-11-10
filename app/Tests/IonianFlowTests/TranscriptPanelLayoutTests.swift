import AppKit
import Foundation
import Testing
@testable import IonianFlow

/// Transcript mini mode, pure logic: pill corners and frames, full-panel frame, click vs drag, prefs, consent reminder.
extension IonianFlowTests {
@Suite struct TranscriptMiniLayout {
    let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = TranscriptLayout.pillSize

    @Test func bottomRightFrame() {  // F1.1
        #expect(PillCorner.bottomRight.frame(size: size, in: vf) == CGRect(x: 1128, y: 12, width: 300, height: 44))
    }

    @Test func nearestCornerAndFrames() {  // F2.1
        #expect(PillCorner.nearest(point: CGPoint(x: 300, y: 700), in: vf) == .topLeft)
        #expect(PillCorner.topLeft.frame(size: size, in: vf) == CGRect(x: 12, y: 819, width: 300, height: 44))
        #expect(PillCorner.topRight.frame(size: size, in: vf) == CGRect(x: 1128, y: 819, width: 300, height: 44))
        #expect(PillCorner.bottomLeft.frame(size: size, in: vf) == CGRect(x: 12, y: 12, width: 300, height: 44))
    }

    @Test func ties() {  // F2.2
        #expect(PillCorner.nearest(point: CGPoint(x: 720, y: 437.5), in: vf) == .bottomRight)
        #expect(PillCorner.nearest(point: CGPoint(x: 720, y: 700), in: vf) == .topRight)
        #expect(PillCorner.nearest(point: CGPoint(x: 300, y: 437.5), in: vf) == .bottomLeft)
    }

    @Test func secondScreen() {  // F2.3
        let vf2 = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let c = PillCorner.nearest(point: CGPoint(x: 1500, y: 1000), in: vf2)
        #expect(c == .topLeft)
        #expect(c.frame(size: size, in: vf2) == CGRect(x: 1452, y: 999, width: 300, height: 44))
    }

    @Test func fullFrame() {  // F1.4
        #expect(TranscriptPanel.fullFrame(savedWidth: 400, in: vf) == CGRect(x: 1028, y: 12, width: 400, height: 851))
        #expect(TranscriptPanel.fullFrame(savedWidth: 0, in: vf).width == 400)
        #expect(TranscriptPanel.fullFrame(savedWidth: 100, in: vf).width == 300)
        #expect(TranscriptPanel.fullFrame(savedWidth: 1000, in: vf).width == 720)
    }

    @Test func clickVersusDrag() {  // F1.4a
        let o = CGPoint.zero
        #expect(PillClick.isClick(down: o, up: CGPoint(x: 3, y: 0)))
        #expect(PillClick.isClick(down: o, up: CGPoint(x: 4, y: 0)))
        #expect(!PillClick.isClick(down: o, up: CGPoint(x: 5, y: 0)))
        #expect(PillClick.isClick(down: o, up: CGPoint(x: 2.8, y: 2.8)))
    }

    @Test func modeChangeDuration() {  // F1.9, SC2
        #expect(TranscriptPanel.modeChangeDuration(reduceMotion: true) == 0)
        #expect(TranscriptPanel.modeChangeDuration(reduceMotion: false) == 0.25)
    }

    @Test func styleAndMinSize() {  // F1.11
        #expect(!TranscriptPanel.styleMask(for: .mini).contains(.resizable))
        #expect(TranscriptPanel.styleMask(for: .mini).contains(.nonactivatingPanel))
        #expect(TranscriptPanel.styleMask(for: .full).contains(.resizable))
        #expect(TranscriptPanel.minSize(for: .mini) == CGSize(width: 300, height: 44))
        #expect(TranscriptPanel.minSize(for: .full) == WindowLayout.transcriptMin)
    }

    let a = ScreenRect(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    let b = ScreenRect(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

    @Test func dropScreenPicksCenterThenPointerThenMain() {  // F2.1, F2.3
        let s = [a, b]
        #expect(PillPlacement.dropScreen(center: CGPoint(x: 1500, y: 10), pointer: CGPoint(x: 10, y: 10), screens: s, main: a) == b)
        #expect(PillPlacement.dropScreen(center: CGPoint(x: 9999, y: 9999), pointer: CGPoint(x: 10, y: 10), screens: s, main: b) == a)
        #expect(PillPlacement.dropScreen(center: CGPoint(x: 9999, y: 9999), pointer: CGPoint(x: -5, y: -5), screens: s, main: b) == b)
        #expect(PillPlacement.dropScreen(center: .zero, pointer: .zero, screens: [], main: nil) == nil)
    }

    @Test func targetScreen() {
        #expect(PillPlacement.targetScreen(pointer: CGPoint(x: 1500, y: 10), screens: [a, b], main: a) == b)
        #expect(PillPlacement.targetScreen(pointer: CGPoint(x: -1, y: -1), screens: [a, b], main: a) == a)
        #expect(PillPlacement.targetScreen(pointer: .zero, screens: [], main: nil) == nil)
    }

    @Test func screenAfterChange() {  // F2.6
        let bigger = ScreenRect(id: 2, frame: b.frame, visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1000))
        #expect(PillPlacement.screenAfterChange(ownID: 2, pointer: CGPoint(x: 10, y: 10), screens: [a, bigger], main: a) == bigger)
        #expect(PillPlacement.screenAfterChange(ownID: 2, pointer: CGPoint(x: 10, y: 10), screens: [a], main: a) == a)
        let aChanged = ScreenRect(id: 1, frame: a.frame, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 800))
        #expect(PillPlacement.screenAfterChange(ownID: 2, pointer: .zero, screens: [aChanged, b], main: aChanged) == b)
    }

    private func isolated(_ body: (UserDefaults) -> Void) {
        let name = "test.\(UUID())"
        let d = UserDefaults(suiteName: name)!
        body(d)
        d.removePersistentDomain(forName: name)
    }

    @Test func prefsDefaultsAndGarbage() {  // F2.4, F3.6
        isolated { d in
            let p = TranscriptPanelPrefs(defaults: d)
            #expect(p.mode == .full)
            #expect(p.corner == .bottomRight)
            d.set("huge", forKey: TranscriptPanelPrefs.modeKey)
            d.set("middle", forKey: TranscriptPanelPrefs.cornerKey)
            #expect(p.mode == .full)
            #expect(p.corner == .bottomRight)
        }
    }

    @Test func prefsPersist() {  // SC3
        isolated { d in
            let p = TranscriptPanelPrefs(defaults: d)
            p.mode = .mini
            p.corner = .topLeft
            let q = TranscriptPanelPrefs(defaults: d)
            #expect(q.mode == .mini)
            #expect(q.corner == .topLeft)
            #expect(d.string(forKey: "transcriptPanelMode") == "mini")
            #expect(d.string(forKey: "transcriptPillCorner") == "topLeft")
        }
    }

    @Test func consentReminderWindow() {  // F3.1, F3.3
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var r = ConsentReminder()
        #expect(!r.isShowing(at: t0))
        #expect(r.endsAt() == nil)
        r.start(at: t0)
        #expect(r.isShowing(at: t0))
        #expect(r.isShowing(at: t0.addingTimeInterval(4.9)))
        #expect(!r.isShowing(at: t0.addingTimeInterval(5)))
        #expect(!r.isShowing(at: t0.addingTimeInterval(6)))
        #expect(r.endsAt() == t0.addingTimeInterval(5))
    }

    @Test func consentReminderCancel() {  // F3.4, SC7
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var r = ConsentReminder()
        r.start(at: t0)
        r.cancel()
        #expect(!r.isShowing(at: t0.addingTimeInterval(1)))
        #expect(r.endsAt() == nil)
    }
}
}
