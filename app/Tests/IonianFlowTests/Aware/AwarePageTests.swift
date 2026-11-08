import Foundation
import Testing
@testable import IonianFlow

// Spec F3: the Aware settings page. Its logic is pure, so it is tested without SwiftUI.
@MainActor @Suite struct AwarePageTests {
    static let utc = TimeZone(identifier: "UTC")!
    static func at(_ s: String) -> Date { TranscriptSourceTests.local(s) }
    static let brain = URL(fileURLWithPath: "/Users/sample/Ionian/brain", isDirectory: true)

    static func settings(on: Bool = true, hours: Int = 3, paused: Date? = nil) -> AwarePageSettings {
        AwarePageSettings(on: on, intervalHours: hours, pausedUntil: paused)
    }

    // F3.2: switch, last sweep, next, items waiting, brain path.
    @Test func statusWhenOn() {
        let s = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                       state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 12:00")),
                                       now: Self.at("2026-11-06 13:10"), itemsToday: 4, home: "/Users/sample")
        #expect(s.switchOn && !s.invite)
        #expect(s.statusLines == ["Last sweep 12:00", "Next around 15:00", "4 items waiting"])
        #expect(s.brainPath == "~/Ionian/brain")
        #expect(s.problem == nil)
    }

    @Test func itemsWaitingWording() {
        func lines(_ n: Int) -> [String] {
            AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                   state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 12:00")),
                                   now: Self.at("2026-11-06 13:10"), itemsToday: n, home: "/h").statusLines
        }
        #expect(lines(1)[2] == "1 item waiting")
        #expect(lines(0)[2] == "Nothing waiting")
    }

    @Test func intervalDecidesNext() {
        let s = AwarePageState.make(settings: Self.settings(hours: 2), brain: Self.brain, cleanupInstalled: true,
                                       state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 12:00")),
                                       now: Self.at("2026-11-06 12:30"), itemsToday: 0, home: "/h")
        #expect(s.statusLines[1] == "Next around 14:00")
    }

    @Test func noSweepYetAndOverdueSayNextSoon() {
        let none = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true, state: AwareState(),
                                          now: Self.at("2026-11-06 12:30"), itemsToday: 0, home: "/h")
        #expect(none.statusLines.prefix(2) == ["No sweep yet", "Next sweep soon"])
        let late = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                          state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 07:00")),
                                          now: Self.at("2026-11-06 12:30"), itemsToday: 0, home: "/h")
        #expect(late.statusLines[1] == "Next sweep soon")
    }

    @Test func otherDaysAreNamed() {
        let s = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                       state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-05 23:00")),
                                       now: Self.at("2026-11-06 00:30"), itemsToday: 0, home: "/h")
        #expect(s.statusLines[0] == "Last sweep yesterday 23:00")
        #expect(s.statusLines[1] == "Next around 02:00")
        let t = AwarePageState.make(settings: Self.settings(), brain: Self.brain, cleanupInstalled: true,
                                       state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 22:00")),
                                       now: Self.at("2026-11-06 22:30"), itemsToday: 0, home: "/h")
        #expect(t.statusLines[1] == "Next around tomorrow 01:00")
    }

    @Test func offShowsNoStatusAndActionsAreOff() {
        let s = AwarePageState.make(settings: Self.settings(on: false), brain: Self.brain, cleanupInstalled: true,
                                       state: AwareState(), now: Self.at("2026-11-06 12:30"), itemsToday: 0, home: "/h")
        #expect(!s.switchOn && s.statusLines.isEmpty && s.problem == nil && !s.invite)
        #expect(!s.canSweep && !s.canPause)
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
                                       state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 12:00")),
                                       now: Self.at("2026-11-06 13:10"), itemsToday: 2, home: "/h")
        #expect(s.problem == AwareApp.noModelDetail && !s.invite)
        #expect(s.switchOn && s.canOpenInbox && s.canPause && s.showsActions)
        #expect(!s.canSweep)
        #expect(s.statusLines.isEmpty)
    }

    // F3.11: while paused the page says until when, and Next waits for the pause.
    @Test func pausedLine() {
        let until = Self.at("2026-11-06 14:05")
        #expect(AwareApp.pausedLine(until: until, now: Self.at("2026-11-06 13:10")) == "Paused until 14:05")
        #expect(AwareApp.pausedLine(until: until, now: Self.at("2026-11-06 14:05")) == nil)
        #expect(AwareApp.pausedLine(until: nil, now: Self.at("2026-11-06 14:05")) == nil)
        let s = AwarePageState.make(settings: Self.settings(paused: until), brain: Self.brain, cleanupInstalled: true,
                                       state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 12:00")),
                                       now: Self.at("2026-11-06 13:10"), itemsToday: 1, home: "/h")
        #expect(s.pausedLine == "Paused until 14:05")
        #expect(s.statusLines[1] == "Next around 15:00")
        let long = AwarePageState.make(settings: Self.settings(hours: 1, paused: until), brain: Self.brain, cleanupInstalled: true,
                                          state: AwareState(enabledAt: nil, swept: [], lastSweep: Self.at("2026-11-06 12:00")),
                                          now: Self.at("2026-11-06 13:10"), itemsToday: 1, home: "/h")
        #expect(long.statusLines[1] == "Next around 14:05")
    }

    @Test func copyIsCalm() {
        let all = [AwarePage.headline, AwarePage.lead] + AwarePage.kindLines.map(\.1) + AwarePage.otherCopy
        for t in all {
            #expect(!t.contains("!") && !t.contains("\u{2014}") && !t.contains("\u{2013}") && !t.contains("\n") && !t.contains(" - "))
        }
        #expect(AwarePage.headline.hasSuffix("."))
    }

    @Test func intervalTitles() {
        #expect(AwarePage.intervals == [1, 2, 3, 6])
        #expect(AwarePage.intervalTitle(1) == "Every hour")
        #expect(AwarePage.intervalTitle(3) == "Every 3 hours")
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

    // F3.10: adding puts the bundle id on the list once; removing takes it off.
    @Test func excludedApps() {
        #expect(AwareRules.adding("com.apple.Notes", to: ["a"]) == ["a", "com.apple.Notes"])
        #expect(AwareRules.adding("a", to: ["a"]) == ["a"])
        #expect(AwareRules.adding("", to: ["a"]) == ["a"])
        #expect(AwareRules.removing("a", from: ["a", "b"]) == ["b"])
        let added = AwareRules.adding("com.apple.Notes", to: [])
        #expect(!AwareRules.shouldCapture(bundle: "com.apple.Notes", excluded: added, secureInput: false, pausedUntil: nil, now: Date()))
        let removed = AwareRules.removing("com.apple.Notes", from: added)
        #expect(AwareRules.shouldCapture(bundle: "com.apple.Notes", excluded: removed, secureInput: false, pausedUntil: nil, now: Date()))
    }

    @Test func excludedAppNames() {
        let rows = AwarePageState.excludedRows(["com.1password.1password", "com.example.Tool", "com.apple.Notes"]) {
            $0 == "com.apple.Notes" ? "Notes" : nil
        }
        #expect(rows.map(\.name) == ["1Password", "com.example.Tool", "Notes"])
        #expect(rows.map(\.bundle) == ["com.1password.1password", "com.example.Tool", "com.apple.Notes"])
    }

    @Test func bundleIdOfAnAppFolder() throws {
        let app = try TranscriptSourceTests.tmp().appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.Tool"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(AwareApp.bundleID(ofApp: app) == "com.example.Tool")
        #expect(AwareApp.bundleID(ofApp: try TranscriptSourceTests.tmp()) == nil)
    }

    // F3.5 stored kinds: default all three; unknown words are ignored.
    @Test func kindsFromStoredWords() {
        #expect(AwareApp.kinds(stored: nil) == Set(AwareCategory.allCases))
        #expect(AwareApp.kinds(stored: ["todo", "fact", "x"]) == [.todo, .fact])
        #expect(AwareApp.kinds(stored: []) == [])
    }

    // F3.7, F3.8
    @Test func clearDeletesTheBuffer() throws {
        let folder = try TranscriptSourceTests.tmp()
        let buffer = CaptureBuffer(folder: folder)
        buffer.append(text: "Remind me to renew the vendor contract", app: "Notes", bundle: "com.apple.Notes")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("buffer.jsonl").path))
        buffer.clear()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("buffer.jsonl").path))
        #expect(buffer.read().isEmpty)
        buffer.clear()   // nothing there is fine
    }

    private func filled() throws -> (folder: URL, buffer: CaptureBuffer) {
        let folder = try TranscriptSourceTests.tmp()
        let buffer = CaptureBuffer(folder: folder)
        buffer.append(text: "Remind me to renew the vendor contract", app: "Notes", bundle: "com.apple.Notes")
        return (folder, buffer)
    }

    @Test func switchingAwareOffDeletesBuffer() throws {
        let f = try filled()
        AwareApp.disable(folder: f.folder)
        #expect(f.buffer.read().isEmpty)
    }

    @Test func switchingDictationsOffDeletesBufferAndStopsCapture() throws {
        let f = try filled()
        AwareApp.setDictations(on: false, folder: f.folder)
        #expect(f.buffer.read().isEmpty)
        let stored = AwareApp.capture(text: "Remind me to renew the vendor contract", front: (name: "Notes", bundle: "com.apple.Notes"),
                                         excluded: [], secureInput: false, pausedUntil: nil, now: Date(), buffer: f.buffer, dictations: false)
        #expect(!stored && f.buffer.read().isEmpty)
        let on = AwareApp.capture(text: "Remind me to renew the vendor contract", front: (name: "Notes", bundle: "com.apple.Notes"),
                                     excluded: [], secureInput: false, pausedUntil: nil, now: Date(), buffer: f.buffer, dictations: true)
        #expect(on)
        AwareApp.setDictations(on: true, folder: f.folder)
        #expect(f.buffer.read().count == 1)   // switching on deletes nothing
    }

    // F3.6: turning Meetings on moves enabledAt to now; off leaves it.
    @Test func switchingMeetingsOnSetsEnabledAt() throws {
        let folder = try TranscriptSourceTests.tmp()
        let first = Self.at("2026-11-01 08:00"), later = Self.at("2026-11-06 12:00")
        AwareApp.enable(folder: folder, now: first)
        AwareApp.setMeetings(on: false, folder: folder, now: later)
        #expect(AwareState.load(from: folder).enabledAt == first)
        AwareApp.setMeetings(on: true, folder: folder, now: later)
        #expect(AwareState.load(from: folder).enabledAt == later)
    }

    // F3.6: with Meetings off, the finished meeting does not start a sweep.
    @Test func meetingEndedIgnoredWhenMeetingsOff() async {
        let e = SchedulerEnv()
        var meetings = false
        let s = AwareScheduler(
            sweeper: e.sweeper, gate: e.gate, clock: { e.now }, isBusy: { false },
            brainReady: { true }, modelReady: { true }, intervalHours: { 3 }, pausedUntil: { nil },
            loadState: { e.state }, saveState: { _ in }, meetingsOn: { meetings })
        s.meetingEnded(URL(fileURLWithPath: "/tmp/m.md"))
        await s.running?.value
        #expect(e.sweeper.runs == [])
        meetings = true
        s.meetingEnded(URL(fileURLWithPath: "/tmp/m.md"))
        await s.running?.value
        #expect(e.sweeper.runs == [.meeting(URL(fileURLWithPath: "/tmp/m.md"))])
    }
}

// F3.5, F3.6, F3.7 in the sweep.
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
        let r = await sweep.run(kind: .scheduled, transcript: nil, checkpoint: AwareSweepTests.noCheckpoint)
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

    @Test func meetingsOffReadsNoTranscriptAndRecordsNothing() async throws {
        let f = try F()
        try f.addTranscript()
        f.dictate("Remind me to send the invoice to the vendor tomorrow")
        var sweep = f.sweep
        sweep.readsMeetings = false
        _ = await sweep.run(kind: .scheduled, transcript: nil, checkpoint: AwareSweepTests.noCheckpoint)
        #expect(f.model.extractCalls.flatMap { $0 }.allSatisfy { if case .dictation = $0.kind { true } else { false } })
        #expect(!f.model.extractCalls.isEmpty)
        #expect(AwareState.load(from: f.aware).swept.isEmpty)
        // A meeting sweep does nothing either.
        let r = await sweep.run(kind: .meeting, transcript: f.transcripts.appendingPathComponent(AwareSweepTests.transcriptName), checkpoint: AwareSweepTests.noCheckpoint)
        #expect(r.written == 0)
    }

    @Test func dictationsOffReadsNoBuffer() async throws {
        let f = try F()
        try f.addTranscript()
        f.dictate("Remind me to send the invoice to the vendor tomorrow")
        var sweep = f.sweep
        sweep.readsDictations = false
        _ = await sweep.run(kind: .scheduled, transcript: nil, checkpoint: AwareSweepTests.noCheckpoint)
        #expect(f.model.extractCalls.flatMap { $0 }.allSatisfy { if case .transcript = $0.kind { true } else { false } })
        #expect(!f.model.extractCalls.isEmpty)
    }
}
