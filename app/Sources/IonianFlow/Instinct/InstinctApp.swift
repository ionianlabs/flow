import Foundation

/// Makes `InstinctSweep` the scheduler's `InstinctSweeping`. The sweep is built per run, so a changed brain or
/// transcripts folder is picked up; nil (no brain, no model) is a failed run.
struct InstinctSweepAdapter: InstinctSweeping, @unchecked Sendable {
    var build: @Sendable (SweepControl) -> InstinctSweep?

    func run(_ request: InstinctSweepRequest, gate: InstinctGate) async -> InstinctSweepOutcome {
        guard let sweep = build(gate.control) else { return .failed }
        let checkpoint: () async -> Void = { await gate.checkpoint() }
        let report: InstinctSweepReport
        switch request {
        case .scheduled: report = await sweep.run(kind: .scheduled, transcript: nil, checkpoint: checkpoint)
        case .meeting(let url): report = await sweep.run(kind: .meeting, transcript: url, checkpoint: checkpoint)
        }
        return report.failed ? .failed : .done(capReached: report.capReached)
    }
}

/// App glue for Instinct that has rules worth testing: where the files live, when a dictation is captured,
/// what happens when the setting flips, the pause and the menu lines.
enum InstinctApp {
    /// The model of a sweep: Gemma, paused through the sweep's control. Nil (tests) is reported as "model not downloaded".
    nonisolated(unsafe) static var makeModel: ((SweepControl) -> InstinctModel)? = { GemmaInstinctModel(control: $0) }

    /// The sweep of the running app: the connected brain, the transcripts folder, the Instinct folder.
    static func liveSweep(_ control: SweepControl) -> InstinctSweep? {
        guard let make = makeModel, let brain = BrainLocator.current() else { return nil }
        return InstinctSweep(brainRoot: brain, transcriptsFolder: Settings.transcriptsFolder,
                             instinctFolder: Settings.instinctFolder, model: make(control),
                             kinds: Settings.instinctKinds, readsMeetings: Settings.instinctMeetings,
                             readsDictations: Settings.instinctDictations)
    }

    // MARK: folder

    /// `<testDir>/Instinct` under `IONIAN_FLOW_TEST_DIR`, else the Application Support folder of Ionian Flow.
    static func folder(testDir: URL?, home: URL) -> URL {
        if let testDir { return testDir.appendingPathComponent("Instinct", isDirectory: true) }
        return home.appendingPathComponent("Library/Application Support/Ionian Flow/Instinct", isDirectory: true)
    }

    // MARK: capture (F1.1 to F1.4)

    /// Appends the delivered text to the buffer when the rules allow it; true when stored.
    /// Without a known front app nothing is stored, since the exclusion list could not be applied.
    @discardableResult
    static func capture(text: String, front: (name: String, bundle: String)?, excluded: [String], secureInput: Bool,
                        pausedUntil: Date?, now: Date, buffer: CaptureBuffer, dictations: Bool = true) -> Bool {
        guard dictations, !text.isEmpty, let front, !front.bundle.isEmpty,
              InstinctRules.shouldCapture(bundle: front.bundle, excluded: excluded, secureInput: secureInput,
                                          pausedUntil: pausedUntil, now: now) else { return false }
        return buffer.append(text: text, app: front.name, bundle: front.bundle) != nil
    }

    // MARK: enabling (F1.35)

    /// Turning Instinct on records the moment in `state.json`; turning it off and on again moves it.
    static func enable(folder: URL, now: Date) {
        var state = InstinctState.load(from: folder)
        state.enabledAt = now
        do { try state.save(to: folder) } catch { NSLog("Ionian Flow: Instinct state not saved: %@", error.localizedDescription) }
    }

    // MARK: Instinct page settings (F3)

    /// Turning Instinct off leaves no dictation on disk (F3.8).
    static func disable(folder: URL) { CaptureBuffer(folder: folder).clear() }

    /// Switching Dictations off stops capture, and deletes what was captured (F3.7).
    static func setDictations(on: Bool, folder: URL) { if !on { CaptureBuffer(folder: folder).clear() } }

    /// Switching Meetings on starts the clock again, so meetings from the off period are not swept (F3.6).
    static func setMeetings(on: Bool, folder: URL, now: Date) { if on { enable(folder: folder, now: now) } }

    /// The kinds to look for from the stored words; nothing stored means all three (F3.5).
    static func kinds(stored: [String]?) -> Set<InstinctCategory> {
        guard let stored else { return Set(InstinctCategory.allCases) }
        return Set(stored.compactMap(InstinctCategory.init(rawValue:)))
    }

    static let notABrain = "That folder is not an Ionian Brain."

    /// A chosen folder is kept only when it is an Ionian Brain (F3.3); the old choice stays otherwise.
    static func chooseBrain(_ url: URL, save: (URL) -> Void) -> Bool {
        guard BrainLines.isBrain(url) else { return false }
        save(url)
        return true
    }

    /// The inbox is part of the Brain's structure and cannot be moved (F3.4).
    static func inbox(of brain: URL) -> URL { brain.appendingPathComponent("inbox", isDirectory: true) }

    /// The bundle id of an `.app` folder picked in the open panel (F3.10).
    static func bundleID(ofApp url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

    /// "Paused until 14:05" while the pause lasts (F3.11).
    static func pausedLine(until: Date?, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let until, until > now else { return nil }
        return "Paused until " + InstinctPageState.clock(until, timeZone: timeZone)
    }

    // MARK: menu (F1.4, F1.28, F1.31)

    static let sweepNowTitle = "Sweep now"
    static let pauseTitle = "Pause Instinct for 1 hour"
    static let resumeTitle = "Resume Instinct"
    static let pauseDuration: TimeInterval = 3600

    static func pauseEnd(from now: Date) -> Date { now.addingTimeInterval(pauseDuration) }

    /// The titles to show when Instinct is on: the status line (disabled) first when there is one, then the two actions.
    static func menuLines(status: String?, pausedUntil: Date? = nil, now: Date = Date()) -> (status: String?, actions: [String]) {
        if let until = pausedUntil, until > now {  // F3.16: paused, the one thing left to do is resume.
            return ("Instinct: paused until " + InstinctPageState.clock(until), [resumeTitle])
        }
        return (status, [sweepNowTitle, pauseTitle])
    }

    // MARK: notice (F1.41)

    struct Notice: Equatable { var title: String; var body: String }

    private static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// "1 meeting and 3 dictations", "3 dictations", or nil when nothing was read.
    static func readText(meetings: Int, dictations: Int) -> String? {
        let parts = (meetings > 0 ? [count(meetings, "meeting")] : []) + (dictations > 0 ? [count(dictations, "dictation")] : [])
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// Proposals always notify. "Nothing" and a failure only answer a sweep the user asked for: the page shows them otherwise.
    static func notice(_ r: InstinctSweepResult, manual: Bool) -> Notice? {
        let read = readText(meetings: r.meetings, dictations: r.dictations)
        if r.written > 0 {
            return Notice(title: "Instinct wrote \(count(r.written, "proposal")) to your inbox.",
                          body: (read.map { "From \($0). " } ?? "") + "Open to review.")
        }
        guard manual else { return nil }
        if r.failed { return Notice(title: "Instinct could not read this time.", body: "Nothing was lost. It tries again soon.") }
        guard let read else { return Notice(title: "Nothing new for Instinct to read.", body: "It reads new dictations and finished meetings.") }
        return Notice(title: "Instinct found nothing to propose.", body: "It read \(read).")
    }

    // MARK: Instinct page copy

    static let toggleTitle = "Instinct"
    static let toggleDetail = "Proposes to-dos, decisions and facts to your brain's inbox."
    /// With no Brain the page invites instead of blocking (F3.15): the Brain is why Instinct is worth having.
    static let noBrainDetail = "Instinct works with your Ionian Brain: one folder of plain notes your agents already read."
    static let getBrainPill = "Get Ionian Brain"
    static let connectBrainTitle = "I have one, connect it ›"
    static let noModelDetail = "Instinct reads with the cleanup model. Download it on the General page."
    static let getBrainTitle = "Get Ionian Brain ↗"
    static let getBrainURL = URL(string: "https://github.com/ionianlabs/brain")!

    /// What the top of the Instinct page shows. The switch is always usable: without a Brain, flipping it leads to the
    /// invitation (`flip`), and a stored "on" stays on, since the scheduler already refuses to sweep.
    struct Row: Equatable {
        var detail: String
        var enabled: Bool
        var shownOn: Bool
        var showsLink: Bool
    }

    static func row(brainFound: Bool, on: Bool, cleanupInstalled: Bool) -> Row {
        if !brainFound { return Row(detail: noBrainDetail, enabled: true, shownOn: on, showsLink: true) }
        if on && !cleanupInstalled { return Row(detail: noModelDetail, enabled: true, shownOn: true, showsLink: false) }
        return Row(detail: toggleDetail, enabled: true, shownOn: on, showsLink: false)
    }

    enum Flip: Equatable { case apply, invite }

    /// Switching on without a Brain does not turn Instinct on: the page moves focus to the invitation (F3.15).
    static func flip(to on: Bool, brainFound: Bool) -> Flip { on && !brainFound ? .invite : .apply }
}
