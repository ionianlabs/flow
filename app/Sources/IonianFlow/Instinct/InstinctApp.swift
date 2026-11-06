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
                             instinctFolder: Settings.instinctFolder, model: make(control))
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
                        pausedUntil: Date?, now: Date, buffer: CaptureBuffer) -> Bool {
        guard !text.isEmpty, let front, !front.bundle.isEmpty,
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

    // MARK: menu (F1.4, F1.28, F1.31)

    static let sweepNowTitle = "Sweep now"
    static let pauseTitle = "Pause Instinct for 1 hour"
    static let pauseDuration: TimeInterval = 3600

    static func pauseEnd(from now: Date) -> Date { now.addingTimeInterval(pauseDuration) }

    /// The titles to show when Instinct is on: the status line (disabled) first when there is one, then the two actions.
    static func menuLines(status: String?) -> (status: String?, actions: [String]) {
        (status, [sweepNowTitle, pauseTitle])
    }

    // MARK: General page copy

    static let toggleTitle = "Instinct"
    static let toggleDetail = "Proposes to-dos, decisions and facts to your brain's inbox."
    static let noBrainDetail = "Needs an Ionian Brain. Connect one under Vocabulary."
    static let noModelDetail = "Needs the cleanup model. Download it under Models."
    static let getBrainTitle = "Get Ionian Brain ↗"
    /// Whether a brain is found; the renderer swaps it for sample states.
    nonisolated(unsafe) static var brainFound: () -> Bool = { BrainLocator.current() != nil }
    static let getBrainURL = URL(string: "https://github.com/ionianlabs/brain")!

    /// What the General page row shows. Without a brain the toggle is disabled (off), and the detail points to one;
    /// a stored "on" stays on, and can still be switched off, since the scheduler already refuses to sweep.
    struct Row: Equatable {
        var detail: String
        var enabled: Bool
        var shownOn: Bool
        var showsLink: Bool
    }

    static func row(brainFound: Bool, on: Bool, cleanupInstalled: Bool) -> Row {
        if !brainFound { return Row(detail: noBrainDetail, enabled: on, shownOn: on, showsLink: true) }
        if on && !cleanupInstalled { return Row(detail: noModelDetail, enabled: true, shownOn: true, showsLink: false) }
        return Row(detail: toggleDetail, enabled: true, shownOn: on, showsLink: false)
    }
}
