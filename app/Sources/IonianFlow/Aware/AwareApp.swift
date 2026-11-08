import Foundation

/// Makes `AwareSweep` the scheduler's `AwareSweeping`. The sweep is built per run, so a changed brain or
/// transcripts folder is picked up; nil (no brain, no model) is a failed run.
struct AwareSweepAdapter: AwareSweeping, @unchecked Sendable {
    var build: @Sendable (SweepControl) -> AwareSweep?

    func run(_ request: AwareSweepRequest, gate: AwareGate) async -> AwareSweepOutcome {
        guard let sweep = build(gate.control) else { return .failed }
        let checkpoint: () async -> Void = { await gate.checkpoint() }
        let report: AwareSweepReport
        switch request {
        case .catchUp: report = await sweep.run(kind: .catchUp, transcript: nil, checkpoint: checkpoint)
        case .meeting(let url): report = await sweep.run(kind: .meeting, transcript: url, checkpoint: checkpoint)
        }
        return report.failed ? .failed : .done(capReached: report.capReached)
    }
}

/// App glue for Aware that has rules worth testing: where the files live,
/// what happens when the setting flips, the notice and the menu lines.
enum AwareApp {
    /// The model of a sweep: Gemma, paused through the sweep's control. Nil (tests) is reported as "model not downloaded".
    nonisolated(unsafe) static var makeModel: ((SweepControl) -> AwareModel)? = { GemmaAwareModel(control: $0) }

    /// The sweep of the running app: the connected brain, the transcripts folder, the Aware folder.
    static func liveSweep(_ control: SweepControl) -> AwareSweep? {
        guard let make = makeModel, let brain = BrainLocator.current() else { return nil }
        return AwareSweep(brainRoot: brain, transcriptsFolder: Settings.transcriptsFolder,
                             awareFolder: Settings.awareFolder, model: make(control),
                             kinds: Settings.awareKinds)
    }

    // MARK: folder

    /// `<testDir>/Aware` under `IONIAN_FLOW_TEST_DIR`, else the Application Support folder of Ionian Flow.
    static func folder(testDir: URL?, home: URL) -> URL {
        if let testDir { return testDir.appendingPathComponent("Aware", isDirectory: true) }
        return home.appendingPathComponent("Library/Application Support/Ionian Flow/Aware", isDirectory: true)
    }

    // MARK: enabling (F1.35)

    /// Turning Aware on records the moment in `state.json`; turning it off and on again moves it.
    static func enable(folder: URL, now: Date) {
        var state = AwareState.load(from: folder)
        state.enabledAt = now
        do { try state.save(to: folder) } catch { NSLog("Ionian Flow: Aware state not saved: %@", error.localizedDescription) }
    }

    // MARK: Aware page settings (F3)

    /// The kinds to look for from the stored words; nothing stored means all three (F3.5).
    static func kinds(stored: [String]?) -> Set<AwareCategory> {
        guard let stored else { return Set(AwareCategory.allCases) }
        return Set(stored.compactMap(AwareCategory.init(rawValue:)))
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

    // MARK: menu (F1.28, F1.31)

    static let sweepNowTitle = "Sweep now"

    /// The titles to show when Aware is on: the status line (disabled) first when there is one, then the one action.
    static func menuLines(status: String?) -> (status: String?, actions: [String]) {
        (status, [sweepNowTitle])
    }

    // MARK: notice (F1.41)

    struct Notice: Equatable { var title: String; var body: String }

    private static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// "1 meeting", "2 meetings", or nil when nothing was read.
    static func readText(meetings: Int) -> String? { meetings > 0 ? count(meetings, "meeting") : nil }

    /// Proposals always notify. "Nothing" and a failure only answer a sweep the user asked for: the page shows them otherwise.
    static func notice(_ r: AwareSweepResult, manual: Bool) -> Notice? {
        let read = readText(meetings: r.meetings)
        if r.written > 0 {
            return Notice(title: "Aware wrote \(count(r.written, "proposal")) to your inbox.",
                          body: "From \(read ?? count(r.meetings, "meeting")). Open to review.")
        }
        guard manual else { return nil }
        if r.failed { return Notice(title: "Aware could not read this time.", body: "Nothing was lost. It tries again soon.") }
        guard let read else { return Notice(title: "Nothing new for Aware to read.", body: "It reads meetings when they end.") }
        return Notice(title: "Aware found nothing to propose.", body: "It read \(read).")
    }

    // MARK: Aware page copy

    static let toggleTitle = "Aware"
    static let toggleDetail = "Proposes to-dos, decisions and facts from your meetings to your brain's inbox."
    /// With no Brain the page invites instead of blocking (F3.15): the Brain is why Aware is worth having.
    static let noBrainDetail = "Aware works with your Ionian Brain: one folder of plain notes your agents already read."
    static let getBrainPill = "Get Ionian Brain"
    static let connectBrainTitle = "I have one, connect it ›"
    static let noModelDetail = "Aware reads with the cleanup model. Download it on the General page."
    static let getBrainTitle = "Get Ionian Brain ↗"
    static let getBrainURL = URL(string: "https://github.com/ionianlabs/brain")!

    /// What the top of the Aware page shows. The switch is always usable: without a Brain, flipping it leads to the
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

    /// Switching on without a Brain does not turn Aware on: the page moves focus to the invitation (F3.15).
    static func flip(to on: Bool, brainFound: Bool) -> Flip { on && !brainFound ? .invite : .apply }
}
