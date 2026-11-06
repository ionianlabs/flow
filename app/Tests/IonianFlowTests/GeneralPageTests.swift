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

    // The Instinct row left General for its own page (F3.1); its rules now feed the top of that page.
    @Test func instinctTopCopy() {
        #expect(InstinctApp.toggleTitle == "Instinct")
        #expect(InstinctApp.toggleDetail == "Proposes to-dos, decisions and facts to your brain's inbox.")
    }

    // F3.15: without a Brain the switch stays usable and the row invites.
    @Test func instinctRowWithoutBrain() {
        let r = InstinctApp.row(brainFound: false, on: false, cleanupInstalled: true)
        #expect(r.detail == InstinctApp.noBrainDetail && r.enabled && !r.shownOn && r.showsLink)
        #expect(InstinctApp.getBrainTitle == "Get Ionian Brain ↗" && InstinctApp.getBrainPill == "Get Ionian Brain")
        #expect(InstinctApp.connectBrainTitle == "I have one, connect it ›")
        #expect(InstinctApp.getBrainURL.absoluteString == "https://github.com/ionianlabs/brain")
        #expect(InstinctApp.noBrainDetail == "Instinct works with your Ionian Brain: one folder of plain notes your agents already read.")
    }

    @Test func instinctRowWithBrain() {
        let off = InstinctApp.row(brainFound: true, on: false, cleanupInstalled: false)
        #expect(off.detail == InstinctApp.toggleDetail && off.enabled && !off.shownOn && !off.showsLink)
        let on = InstinctApp.row(brainFound: true, on: true, cleanupInstalled: true)
        #expect(on.detail == InstinctApp.toggleDetail && on.enabled && on.shownOn)
    }

    @Test func instinctRowOnWithoutModel() {
        let r = InstinctApp.row(brainFound: true, on: true, cleanupInstalled: false)
        #expect(r.detail == InstinctApp.noModelDetail && r.enabled && r.shownOn && !r.showsLink)
    }

    @Test func instinctRowKeepsOnWhenBrainDisappears() {
        let r = InstinctApp.row(brainFound: false, on: true, cleanupInstalled: false)
        #expect(r.shownOn && r.enabled && r.showsLink && r.detail == InstinctApp.noBrainDetail)
    }

    // F3.15: switching on without a Brain leads to the invitation instead of turning on.
    @Test func flippingOnWithoutBrainInvites() {
        #expect(InstinctApp.flip(to: true, brainFound: false) == .invite)
        #expect(InstinctApp.flip(to: true, brainFound: true) == .apply)
        #expect(InstinctApp.flip(to: false, brainFound: false) == .apply)
    }

    @Test func instinctRowCopyIsCalm() {
        for t in [InstinctApp.noBrainDetail, InstinctApp.noModelDetail, InstinctApp.toggleDetail, InstinctApp.getBrainTitle,
                  InstinctApp.getBrainPill, InstinctApp.connectBrainTitle] {
            #expect(!t.contains("!") && !t.contains("\u{2014}") && !t.contains("\u{2013}") && !t.contains("\n"))
        }
        // The invitation never reads as a hurdle.
        for t in [InstinctApp.noBrainDetail, InstinctApp.getBrainPill, InstinctApp.connectBrainTitle] {
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
