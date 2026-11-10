import Foundation
import SwiftUI
import Testing
@testable import IonianFlow

/// The transcript pill's view-model and the clock it shares with the full header (spec transcript-mini).
extension IonianFlowTests {
@Suite struct TranscriptPillSuite {
    private func state(finishing: Bool = false, notice: String? = nil, reminder: Bool = false,
                       elapsed: String = "12:34", hint: String = "Double-tap Right Option") -> TranscriptPillState {
        TranscriptPillState(finishing: finishing, notice: notice, reminder: reminder, elapsed: elapsed, shortcutHint: hint)
    }

    @Test func clockKeepsTheHeadersFormat() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        func e(_ s: Double) -> String { TranscriptClock.elapsed(from: t0, to: t0.addingTimeInterval(s)) }
        #expect(e(0) == "0:00")
        #expect(e(59) == "0:59")
        #expect(e(754) == "12:34")
        #expect(e(3700) == "1:01:40")
        #expect(e(-5) == "0:00")
    }

    @Test func labelPrecedence() {  // F1.6, F3.1, F3.7
        #expect(state().label == "12:34")
        #expect(state(reminder: true).label == "Always get consent when transcribing others.")
        #expect(state(finishing: true).label == "Finishing")
        #expect(state(finishing: true, reminder: true).label == "Finishing")
    }

    @Test func wavesShowExceptDuringTheReminder() {  // F3.1
        #expect(state().showsWaves)
        #expect(!state(reminder: true).showsWaves)
        #expect(state(finishing: true).showsWaves)
        #expect(state(finishing: true, reminder: true).showsWaves)
    }

    @Test func finishingFreezesWavesAndStop() {  // F1.6
        #expect(state().wavesActive && state().stopEnabled)
        #expect(!state(finishing: true).wavesActive)
        #expect(!state(finishing: true).stopEnabled)
    }

    @Test func markerFollowsTheNotice() {  // F1.8, F3.7
        #expect(!state(notice: nil).markerShown)
        #expect(!state(notice: "").markerShown)
        #expect(!state(notice: "  \n").markerShown)
        #expect(state(notice: "Allow Ionian Flow in System Settings").markerShown)
        #expect(state(notice: "Allow", reminder: true).markerShown)
        #expect(state(finishing: true, notice: "Allow").markerShown)
    }

    @Test func controlsFollowHover() {  // F1.3
        #expect(state().controlsVisible(hovering: true))
        #expect(!state().controlsVisible(hovering: false))
    }

    @Test func helpAndAccessibilityTexts() {  // F1.10
        #expect(state().stopHelp == "Stop (or double-tap Right Option)")
        #expect(state().stopAccessibilityLabel == "Stop transcription")
        #expect(state().expandHelp == "Show transcript")
        #expect(state().expandAccessibilityLabel == "Show transcript")
    }

    @Test func metersAreYouAndThem() {  // F1.2
        #expect(state().meters == [.init(label: "You", color: Color.accent), .init(label: "Them", color: Color.muted)])
    }

    @Test func holdsNoTranscriptText() {  // SC4
        let s = state(notice: "A secret notice")
        let strings = Mirror(reflecting: s).children.compactMap { $0.value as? String }
        #expect(Set(strings).isSubset(of: ["12:34", "Double-tap Right Option"]), "\(strings)")
        #expect(!Mirror(reflecting: s).children.contains { "\($0.value)".contains("secret") })
    }
}
}
