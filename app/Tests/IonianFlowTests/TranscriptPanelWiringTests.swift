import AppKit
import Foundation
import Testing
@testable import IonianFlow

/// The transcript panel's mode wiring, driven without ever showing a window (spec transcript-mini).
extension IonianFlowTests {
@MainActor @Suite struct TranscriptPanelWiring {
    private let screen = ScreenRect(id: 9001, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let second = ScreenRect(id: 9002, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                    visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private let pointer = CGPoint(x: 100, y: 100)
    private let pill = TranscriptLayout.pillSize

    private struct Rig {
        let panel: TranscriptPanel
        let model: TranscriptModel
        let prefs: TranscriptPanelPrefs
        let defaults: UserDefaults
        var stops: StopCounter
    }
    private final class StopCounter { var n = 0 }

    private func rig(mode: String? = nil, corner: String? = nil, width: Double? = nil) -> Rig {
        _ = NSApplication.shared
        let suite = "wiring-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        if let mode { d.set(mode, forKey: TranscriptPanelPrefs.modeKey) }
        if let corner { d.set(corner, forKey: TranscriptPanelPrefs.cornerKey) }
        if let width { d.set(width, forKey: "transcriptPanelWidth") }
        let prefs = TranscriptPanelPrefs(defaults: d)
        let model = TranscriptModel()
        let panel = TranscriptPanel(model: model, prefs: prefs)
        let c = StopCounter()
        panel.onStop = { c.n += 1 }
        panel.screensProvider = { [screen, second] }
        panel.mainProvider = { screen }
        panel.panelScreenProvider = { nil }  // the hidden panel may sit on a real screen
        return Rig(panel: panel, model: model, prefs: prefs, defaults: d, stops: c)
    }

    private func start(_ r: Rig, on s: ScreenRect? = nil, now: Date = Date(timeIntervalSinceReferenceDate: 5000)) {
        r.panel.prepareShow(now: now, pointer: pointer, screens: [s ?? screen], main: s ?? screen)
    }

    @Test func hiddenFromScreenSharingInBothModes() {  // F4.1
        let r = rig()
        #expect(r.panel.sharingType == .none)
        r.panel.setMode(.mini)
        #expect(r.panel.sharingType == .none)
    }

    @Test func miniIsNotResizableAndFullRestoresIt() {  // F1.11
        let r = rig()
        start(r)
        r.panel.setMode(.mini)
        #expect(!r.panel.panelStyleMask.contains(.resizable))
        #expect(r.panel.panelMinSize == pill)
        r.panel.setMode(.full)
        #expect(r.panel.panelStyleMask.contains(.resizable))
        #expect(r.panel.panelMinSize == WindowLayout.transcriptMin)
    }

    @Test func minimizeAndExpandMoveTheFrameAndStoreTheMode() {  // F1.1, F1.4
        let r = rig(width: 400)
        start(r)
        #expect(r.panel.panelFrame == TranscriptPanel.fullFrame(savedWidth: 400, in: screen.visibleFrame))
        r.panel.handleMinimize()
        #expect(r.panel.mode == .mini)
        #expect(r.panel.panelFrame == PillCorner.bottomRight.frame(size: pill, in: screen.visibleFrame))
        #expect(r.prefs.mode == .mini)
        r.panel.handleExpand()
        #expect(r.panel.mode == .full)
        #expect(r.panel.panelFrame == TranscriptPanel.fullFrame(savedWidth: 400, in: screen.visibleFrame))
        #expect(r.prefs.mode == .full)
    }

    @Test func theWidthIsRememberedInFullModeOnly() {  // F1.11
        let r = rig(width: 400)
        start(r)
        r.panel.setMode(.mini)
        r.panel.handleLiveResizeEnd()
        #expect(r.defaults.double(forKey: "transcriptPanelWidth") == 400)
        r.panel.setMode(.full)
        r.defaults.set(123.0, forKey: "transcriptPanelWidth")
        r.panel.handleLiveResizeEnd()
        #expect(r.defaults.double(forKey: "transcriptPanelWidth") == 400)
    }

    @Test func stopFromThePillStopsOnceAndStaysMini() {  // F1.5
        let r = rig(mode: "mini")
        start(r)
        r.panel.handlePillStop()
        #expect(r.stops.n == 1)
        #expect(r.panel.mode == .mini)
    }

    @Test func clickOnTheBodyExpandsAndADragSnaps() {  // F1.4a, F2.1
        let r = rig(mode: "mini")
        start(r)
        r.panel.handlePillRelease(down: CGPoint(x: 500, y: 500), up: CGPoint(x: 503, y: 500),
                                  pointer: pointer, screens: [screen], main: screen)
        #expect(r.panel.mode == .full, "3 pt is a click")

        let d = rig(mode: "mini")
        start(d)
        d.panel.handlePillDrag(down: CGPoint(x: 1300, y: 30), current: CGPoint(x: 400, y: 800))
        d.panel.handlePillRelease(down: CGPoint(x: 1300, y: 30), up: CGPoint(x: 400, y: 800),
                                  pointer: CGPoint(x: 400, y: 800), screens: [screen], main: screen)
        #expect(d.panel.mode == .mini, "a drag does not expand")
        #expect(d.prefs.corner == .topLeft)
        #expect(d.panel.panelFrame == PillCorner.topLeft.frame(size: pill, in: screen.visibleFrame))
    }

    @Test func aTenPointReleaseWithoutDragEventsIsNotAClick() {  // F1.4a
        let r = rig(mode: "mini")
        start(r)
        r.panel.handlePillRelease(down: CGPoint(x: 500, y: 500), up: CGPoint(x: 510, y: 500),
                                  pointer: pointer, screens: [screen], main: screen)
        #expect(r.panel.mode == .mini)
        #expect(r.prefs.corner == .bottomRight)
    }

    @Test func endingExpandsWithoutChangingTheStoredMode() async {  // F1.7
        let r = rig(mode: "mini")
        start(r)
        r.model.ended = Date()
        for _ in 0..<50 where r.panel.mode == .mini { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(r.panel.mode == .full)
        #expect(r.prefs.mode == .mini)
        #expect(!r.panel.isReminderShowing)
    }

    @Test func opensInTheStoredMode() {  // F3.1, F3.2, F3.6
        let m = rig(mode: "mini")
        start(m)
        #expect(m.panel.mode == .mini)
        #expect(m.panel.isReminderShowing)
        #expect(m.panel.panelFrame == PillCorner.bottomRight.frame(size: pill, in: screen.visibleFrame))
        for stored in [nil, "full", "banana"] {
            let f = rig(mode: stored)
            start(f)
            #expect(f.panel.mode == .full)
            #expect(!f.panel.isReminderShowing)
        }
    }

    @Test func expandingDuringTheReminderCancelsIt() {  // F3.3
        let r = rig(mode: "mini")
        start(r)
        r.panel.handleExpand()
        #expect(!r.panel.isReminderShowing)
        #expect(r.prefs.mode == .full)
    }

    @Test func minimizingMidSessionShowsNoReminder() {  // F3.5
        let r = rig()
        start(r)
        r.panel.handleMinimize()
        #expect(!r.panel.isReminderShowing)
    }

    @Test func opensInTheStoredCornerOnTheTargetScreen() {  // F2.5
        let r = rig(mode: "mini", corner: "topLeft")
        r.panel.prepareShow(now: Date(), pointer: CGPoint(x: 2000, y: 500), screens: [screen, second], main: screen)
        #expect(r.panel.panelFrame == PillCorner.topLeft.frame(size: pill, in: second.visibleFrame))
    }

    @Test func screenChangesFollowTheOwnScreen() {  // F2.6
        let r = rig(mode: "mini", corner: "topRight")
        r.panel.prepareShow(now: Date(), pointer: pointer, screens: [screen, second], main: screen)
        let resized = ScreenRect(id: 9001, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 775))
        r.panel.handleScreenChange(pointer: CGPoint(x: 2000, y: 500), screens: [resized, second], main: second)
        #expect(r.panel.panelFrame == PillCorner.topRight.frame(size: pill, in: resized.visibleFrame))
        r.panel.handleScreenChange(pointer: CGPoint(x: 2000, y: 500), screens: [second], main: second)
        #expect(r.panel.panelFrame == PillCorner.topRight.frame(size: pill, in: second.visibleFrame))
    }

    @Test func aStrayBodyReleaseWhileFinishingDoesNotExpand() {  // review 1
        let r = rig(mode: "mini")
        start(r)
        r.model.finishing = true
        r.panel.handlePillRelease(down: CGPoint(x: 500, y: 500), up: CGPoint(x: 500, y: 500),
                                  pointer: pointer, screens: [screen], main: screen)
        #expect(r.panel.mode == .mini)
        r.panel.handleExpand()
        #expect(r.panel.mode == .full)
    }

    @Test func aLateGrowCompletionDoesNotRestoreTheFullMinSizeInMini() {  // review 3
        let r = rig()
        start(r)
        r.panel.setMode(.full)
        r.panel.setMode(.mini)
        r.panel.finishGrow()
        #expect(r.panel.panelMinSize == pill)
        r.panel.setMode(.full)
        r.panel.finishGrow()
        #expect(r.panel.panelMinSize == WindowLayout.transcriptMin)
    }

    @Test func modeChangesDropAStaleDrag() {  // review 4
        let r = rig(mode: "mini")
        start(r)
        r.panel.handlePillDrag(down: CGPoint(x: 1300, y: 30), current: CGPoint(x: 400, y: 800))
        r.panel.setMode(.full)
        r.panel.setMode(.mini)
        r.panel.handlePillRelease(down: CGPoint(x: 500, y: 500), up: CGPoint(x: 500, y: 500),
                                  pointer: pointer, screens: [screen], main: screen)
        #expect(r.panel.mode == .full)
    }

    @Test func aRemovedOwnScreenFallsBackToTheFallbackScreen() {  // review 5
        let r = rig(mode: "mini", corner: "topLeft")
        r.panel.prepareShow(now: Date(), pointer: CGPoint(x: 2000, y: 500), screens: [second], main: second)
        r.panel.screensProvider = { [screen] }  // second is gone
        r.panel.setMode(.full)
        r.panel.setMode(.mini)
        #expect(r.panel.panelFrame == PillCorner.topLeft.frame(size: pill, in: screen.visibleFrame))
    }

    @Test func aRestartedSessionShowsTheReminderInMiniAgain() {  // review 7
        let r = rig(mode: "mini")
        start(r)
        r.model.ended = Date()
        r.panel.setMode(.full, store: false)
        r.model.ended = nil
        start(r)
        #expect(r.panel.mode == .mini)
        #expect(r.panel.isReminderShowing)
        #expect(!r.panel.panelStyleMask.contains(.resizable))
    }

    @Test func hidingCancelsTheReminder() {  // review 7
        let r = rig(mode: "mini")
        start(r)
        #expect(r.panel.isReminderShowing)
        r.panel.handleHide()
        #expect(!r.panel.isReminderShowing)
    }
}
}
