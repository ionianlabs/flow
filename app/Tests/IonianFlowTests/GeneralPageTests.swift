import Foundation
import Testing
@testable import IonianFlow

extension IonianFlowTests {
@Suite struct GeneralPageChecks {
    @Test func totalsLine() {
        let totals = GeneralLayout.totals(words: 2545, transcribedSeconds: 1380, savedSeconds: 2799)
        #expect(totals.map(\.label) == ["words", "of meetings", "saved"])
        #expect(totals[1].value == "23 min" && totals[2].value == "≈ 46 min")
        #expect(GeneralLayout.line(totals).hasSuffix(" words · 23 min of meetings · ≈ 46 min saved"))
        let none = GeneralLayout.totals(words: 0, transcribedSeconds: 0, savedSeconds: 0)
        #expect(GeneralLayout.line(none) == "0 words · 0 min of meetings · 0 min saved")
        #expect(GeneralLayout.totals(words: 1, transcribedSeconds: 0, savedSeconds: 30)[0].label == "word")
        #expect(GeneralLayout.totals(words: 1, transcribedSeconds: 0, savedSeconds: 30)[2].value == "0 min")
        #expect(GeneralLayout.duration(3 * 3600) == "3 h" && GeneralLayout.duration(6 * 3600 + 40 * 60) == "6 h 40 min")
    }

    @Test func howToOnlyBeforeFirstUse() {
        #expect(GeneralLayout.showHowTo(words: 0, transcribedSeconds: 0))
        #expect(!GeneralLayout.showHowTo(words: 3, transcribedSeconds: 0))
        #expect(!GeneralLayout.showHowTo(words: 0, transcribedSeconds: 90))
    }

    // The Aware row left General for its own page (F3.1); its rules now feed the top of that page.
    @Test func awareTopCopy() {
        #expect(AwareApp.toggleTitle == "Aware")
        #expect(AwareApp.toggleDetail == "Proposes to-dos, decisions and facts from your meetings to your brain's inbox.")
    }

    // F3.15: without a Brain the switch stays usable and the row invites.
    @Test func awareRowWithoutBrain() {
        let r = AwareApp.row(brainFound: false, on: false, cleanupInstalled: true)
        #expect(r.detail == AwareApp.noBrainDetail && r.enabled && !r.shownOn && r.showsLink)
        #expect(AwareApp.getBrainTitle == "Get Ionian Brain ↗" && AwareApp.getBrainPill == "Get Ionian Brain")
        #expect(AwareApp.connectBrainTitle == "I have one, connect it ›")
        #expect(AwareApp.getBrainURL.absoluteString == "https://github.com/ionianlabs/brain")
        #expect(AwareApp.noBrainDetail == "Aware works with your Ionian Brain: one folder of plain notes your agents already read.")
    }

    @Test func awareRowWithBrain() {
        let off = AwareApp.row(brainFound: true, on: false, cleanupInstalled: false)
        #expect(off.detail == AwareApp.toggleDetail && off.enabled && !off.shownOn && !off.showsLink)
        let on = AwareApp.row(brainFound: true, on: true, cleanupInstalled: true)
        #expect(on.detail == AwareApp.toggleDetail && on.enabled && on.shownOn)
    }

    @Test func awareRowOnWithoutModel() {
        let r = AwareApp.row(brainFound: true, on: true, cleanupInstalled: false)
        #expect(r.detail == AwareApp.noModelDetail && r.enabled && r.shownOn && !r.showsLink)
    }

    @Test func awareRowKeepsOnWhenBrainDisappears() {
        let r = AwareApp.row(brainFound: false, on: true, cleanupInstalled: false)
        #expect(r.shownOn && r.enabled && r.showsLink && r.detail == AwareApp.noBrainDetail)
    }

    // F3.15: switching on without a Brain leads to the invitation instead of turning on.
    @Test func flippingOnWithoutBrainInvites() {
        #expect(AwareApp.flip(to: true, brainFound: false) == .invite)
        #expect(AwareApp.flip(to: true, brainFound: true) == .apply)
        #expect(AwareApp.flip(to: false, brainFound: false) == .apply)
    }

    @Test func awareRowCopyIsCalm() {
        for t in [AwareApp.noBrainDetail, AwareApp.noModelDetail, AwareApp.toggleDetail, AwareApp.getBrainTitle,
                  AwareApp.getBrainPill, AwareApp.connectBrainTitle] {
            #expect(!t.contains("!") && !t.contains("\u{2014}") && !t.contains("\u{2013}") && !t.contains("\n"))
        }
        // The invitation never reads as a hurdle.
        for t in [AwareApp.noBrainDetail, AwareApp.getBrainPill, AwareApp.connectBrainTitle] {
            #expect(!["needs", "requires", "must", "blocked"].contains { t.lowercased().contains($0) })
        }
    }

    @Test func speechRowStatus() {
        let ready: (state: StatusState, word: String) = (.ready, "Ready")
        #expect(SpeechModelRow.status(phase: .installed, recognizer: ready).word == "Ready")
        #expect(SpeechModelRow.status(phase: .downloading(0.4), recognizer: ready).word == "Downloading 40 %")
        #expect(SpeechModelRow.status(phase: .downloading(0.4), recognizer: ready).state == .working)
        #expect(SpeechModelRow.status(phase: .missing, recognizer: ready).word == "Not downloaded")
        #expect(SpeechModelRow.status(phase: .failed("x"), recognizer: ready).word == "Error")
    }
}
}
