import Foundation
import Testing
@testable import IonianFlow

// Spec F3: the Aware settings page. Its logic is pure, so it is tested without SwiftUI.
@MainActor @Suite struct AwarePageTests {
    static let utc = TimeZone(identifier: "UTC")!
    static func at(_ s: String) -> Date { TranscriptSourceTests.local(s) }
    static let brain = URL(fileURLWithPath: "/Users/sample/Ionian/brain", isDirectory: true)

    static func settings(on: Bool = true) -> AwarePageSettings { AwarePageSettings(on: on) }

    static func state(lastAt: String? = nil, meetings: Int = 1, written: Int = 0) -> AwareState {
        var st = AwareState(enabledAt: nil, swept: [])
        if let lastAt { st.lastResult = AwareSweepResult(at: at(lastAt), meetings: meetings, written: written) }
        return st
    }

    // F3.2: switch, last sweep, meetings waiting, items waiting, brain path.
    @Test func statusWhenOn() {
        let s = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                       state: Self.state(lastAt: "2026-11-06 12:00", written: 2),
                                       now: Self.at("2026-11-06 13:10"), itemsToday: 4, pending: 1, home: "/Users/sample")
        #expect(s.switchOn && !s.invite)
        #expect(s.statusLines == ["Last sweep 12:00: read 1 meeting, wrote 2 proposals", "1 meeting waiting", "4 items waiting"])
        #expect(s.brainPath == "~/Ionian/brain")
        #expect(s.problem == nil)
    }

    @Test func itemsAndMeetingsWaitingWording() {
        func lines(items: Int, pending: Int) -> [String] {
            AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                   state: Self.state(lastAt: "2026-11-06 12:00"),
                                   now: Self.at("2026-11-06 13:10"), itemsToday: items, pending: pending, home: "/h").statusLines
        }
        #expect(lines(items: 1, pending: 0) == ["Last sweep 12:00: read 1 meeting, nothing to propose", "1 item waiting"])
        #expect(lines(items: 0, pending: 0)[1] == "Nothing waiting")
        #expect(lines(items: 0, pending: 2)[1] == "2 meetings waiting")
        #expect(lines(items: 0, pending: 1)[1] == "1 meeting waiting")
    }

    @Test func otherDaysAreNamed() {
        let s = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                       state: Self.state(lastAt: "2026-11-05 23:00"),
                                       now: Self.at("2026-11-06 00:30"), itemsToday: 0, home: "/h")
        #expect(s.statusLines[0].hasPrefix("Last sweep yesterday 23:00"))
    }

    @Test func offShowsNoStatusAndActionsAreOff() {
        let s = AwarePageState.make(settings: Self.settings(on: false), brain: Self.brain, cleanupInstalled: true,
                                       state: AwareState(), now: Self.at("2026-11-06 12:30"), itemsToday: 0, home: "/h")
        #expect(!s.switchOn && s.statusLines.isEmpty && s.problem == nil && !s.invite)
        #expect(!s.canSweep)
        #expect(s.showsActions && s.canOpenInbox)
    }

    // F3.12, F3.15: no Brain is an invitation, not a block; no model is one plain sentence.
    @Test func noBrainInvites() {
        let s = AwarePageState.make(settings: Self.settings(on: false), brain: nil, cleanupInstalled: true,
                                       state: AwareState(), now: Self.at("2026-11-06 12:30"), itemsToday: 0, home: "/h")
        #expect(s.invite && s.problem == nil && !s.switchOn)
        #expect(s.brainPath == nil && !s.canOpenInbox && !s.showsActions && !s.canSweep)
        #expect(s.statusLines.isEmpty)
    }

    @Test func noBrainButStoredOnStaysOn() {
        let s = AwarePageState.make(settings: Self.settings(on: true), brain: nil, cleanupInstalled: true,
                                       state: AwareState(), now: Self.at("2026-11-06 12:30"), itemsToday: 0, home: "/h")
        #expect(s.switchOn && s.invite && !s.canSweep)
    }

    @Test func noModelBlocksSweepOnly() {
        let s = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: false,
                                       state: Self.state(lastAt: "2026-11-06 12:00"),
                                       now: Self.at("2026-11-06 13:10"), itemsToday: 2, pending: 1, home: "/h")
        #expect(s.problem == AwareApp.noModelDetail && !s.invite)
        #expect(s.switchOn && s.canOpenInbox && s.showsActions)
        #expect(!s.canSweep)
        #expect(s.statusLines.isEmpty)
    }

    // The page copy names meetings only.
    @Test func copyNamesMeetingsOnly() {
        #expect(AwareApp.toggleDetail == "Proposes to-dos, decisions and facts from your meetings to your brain's inbox.")
        #expect(AwarePage.lead == "Flow reads your finished meetings on this Mac and proposes to-dos, decisions and facts to your brain.")
        #expect(AwarePage.pitch == "Say it in a meeting. Aware keeps the to-dos, decisions and facts.")
        #expect(AwarePage.sweepDetail == "Read waiting meetings now.")
        let all = [AwarePage.headline, AwarePage.lead] + AwarePage.kindLines.map(\.1) + AwarePage.otherCopy
        #expect(!all.contains { $0.lowercased().contains("dictation") })
    }

    @Test func copyIsCalm() {
        let all = [AwarePage.headline, AwarePage.lead] + AwarePage.kindLines.map(\.1) + AwarePage.otherCopy
        for t in all {
            #expect(!t.contains("!") && !t.contains("\u{2014}") && !t.contains("\u{2013}") && !t.contains("\n") && !t.contains(" - "))
        }
        #expect(AwarePage.headline.hasSuffix("."))
    }

    // F3.3: a folder that is a Brain is accepted and saved; any other is refused and nothing is saved.
    @Test func brainChoice() throws {
        let b = try FixtureBrain()
        var saved: URL?
        #expect(AwareApp.chooseBrain(b.root) { saved = $0 })
        #expect(saved == b.root)
        let plain = try TranscriptSourceTests.tmp()
        var other: URL?
        #expect(!AwareApp.chooseBrain(plain) { other = $0 })
        #expect(other == nil)
        #expect(AwareApp.notABrain == "That folder is not an Ionian Brain.")
    }

    @Test func chosenBrainIsTriedFirst() throws {
        let chosen = try FixtureBrain().root, vault = try FixtureBrain().root
        let home = try TranscriptSourceTests.tmp()
        #expect(BrainLocator.find(chosen: chosen, vault: vault, environment: [:], home: home, testDir: nil)?.standardizedFileURL == chosen.standardizedFileURL)
        // A chosen folder that stopped being a Brain falls through to the others.
        let gone = try TranscriptSourceTests.tmp()
        #expect(BrainLocator.find(chosen: gone, vault: vault, environment: [:], home: home, testDir: nil)?.standardizedFileURL == vault.standardizedFileURL)
        #expect(BrainLocator.candidates(chosen: chosen, vault: nil, environment: [:], home: home, testDir: home).first == chosen)
    }

    // F3.4
    @Test func inboxFolder() {
        #expect(AwareApp.inbox(of: Self.brain).path == "/Users/sample/Ionian/brain/inbox")
    }

    // F3.5 stored kinds: default all three; unknown words are ignored.
    @Test func kindsFromStoredWords() {
        #expect(AwareApp.kinds(stored: nil) == Set(AwareCategory.allCases))
        #expect(AwareApp.kinds(stored: ["todo", "fact", "x"]) == [.todo, .fact])
        #expect(AwareApp.kinds(stored: []) == [])
    }
}

// F3.5 in the sweep.
@Suite struct AwarePageSweepTests {
    typealias F = AwareSweepTests.Fixture

    private func twoKinds(_ f: F) {
        let name = AwareSweepTests.transcriptName
        f.model.items = { _ in [
            AwareSweepTests.item(.decision, "Drop the legacy export", quote: "we drop the legacy export, that's decided", source: "\(name)#1", conf: 0.88),
            AwareSweepTests.item(.fact, "The export has 4 columns", quote: "Can you send me the deck by Friday?", source: "\(name)#0", conf: 0.9),
        ] }
    }

    @Test func switchedOffKindIsDroppedBeforeVerifyAndCountedByRules() async throws {
        let f = try F()
        try f.addTranscript()
        twoKinds(f)
        var sweep = f.sweep
        sweep.kinds = [.todo, .decision]
        let r = await sweep.run(kind: .catchUp, transcript: nil, checkpoint: AwareSweepTests.noCheckpoint)
        #expect(r.written == 1)
        #expect(r.dropped.byRules == 1)
        #expect(f.model.verifyCalls.map(\.item.category) == [.decision])
        #expect(!f.dayText().contains("fact:"))
    }

    @Test func allKindsByDefault() async throws {
        let f = try F()
        try f.addTranscript()
        twoKinds(f)
        let r = await f.run()
        #expect(r.written == 2 && r.dropped.byRules == 0)
    }
}
