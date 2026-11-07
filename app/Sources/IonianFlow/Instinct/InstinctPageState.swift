import Foundation

/// The settings the Instinct page's top part depends on.
struct InstinctPageSettings: Equatable {
    var on: Bool
    var intervalHours: Int
    var pausedUntil: Date?
}

/// Copy of the Instinct page (F3). Calm, no hype.
enum InstinctPage {
    static let headline = "It keeps what matters."
    static let lead = "Flow reads your meetings and dictations on this Mac and proposes to-dos, decisions and facts to your brain."
    static let kindLines: [(InstinctCategory, String)] = [
        (.todo, "Things you or someone else agreed to do."),
        (.decision, "Choices that were settled."),
        (.fact, "Names, numbers and dates worth keeping."),
    ]
    static let kindTitles: [InstinctCategory: String] = [.todo: "To-dos", .decision: "Decisions", .fact: "Facts"]
    static let meetingsDetail = "Read right after they end."
    static let dictationsDetail = "Collected as you dictate, read in batches."
    static let excludedNote = "Dictations from these apps are never stored. Password managers are on the list from the start."
    static let sweepDetail = "Read what is waiting now."
    static let pauseDetail = "Nothing is stored and no sweep runs for an hour."
    static let noBrainPath = "No Brain connected yet"
    static let pitch = "Say it once. Instinct keeps the to-dos, decisions and facts."
    static let intervals = [1, 2, 3, 6]

    static func intervalTitle(_ hours: Int) -> String { hours == 1 ? "Every hour" : "Every \(hours) hours" }

    /// Every sentence that is not built from data, for the copy test.
    static var otherCopy: [String] {
        [meetingsDetail, dictationsDetail, excludedNote, sweepDetail, pauseDetail, noBrainPath, pitch, InstinctApp.notABrain,
         InstinctApp.getBrainPill, InstinctApp.connectBrainTitle, InstinctApp.noBrainDetail, InstinctApp.noModelDetail, InstinctApp.toggleDetail] + intervals.map(intervalTitle)
    }
}

/// What the Instinct page shows, from the settings, the brain, the model, the state file, the clock and
/// today's item count (F3.2, F3.11, F3.12). No SwiftUI.
struct InstinctPageState: Equatable {
    var switchOn = false
    /// No Brain: the top section invites with the one ink pill and a link to connect one (F3.15).
    var invite = false
    /// The cleanup model is missing: one plain sentence (F3.12).
    var problem: String?
    /// Last sweep, next, items waiting; empty while off or blocked.
    var statusLines: [String] = []
    var pausedLine: String?
    var brainPath: String?
    var canOpenInbox = false
    /// The actions only exist with a Brain; there is nothing to sweep or pause before.
    var showsActions = false
    var canSweep = false
    var canPause = false
    /// The Sweep now button: off while paused or already reading, and it says why (F3.16).
    var sweepEnabled = false
    var sweepTitle = "Sweep now"
    var sweepDetail = InstinctPage.sweepDetail
    var isPaused = false

    struct ExcludedApp: Equatable, Identifiable {
        var bundle: String
        var name: String
        var id: String { bundle }
    }

    static func make(settings: InstinctPageSettings, brain: URL?, cleanupInstalled: Bool, state: InstinctState,
                     now: Date, itemsToday: Int, collected: Int = 0, sweeping: Bool = false,
                     home: String = NSHomeDirectory(), timeZone: TimeZone = .current) -> InstinctPageState {
        let row = InstinctApp.row(brainFound: brain != nil, on: settings.on, cleanupInstalled: cleanupInstalled)
        var s = InstinctPageState()
        s.switchOn = row.shownOn
        s.invite = brain == nil
        s.problem = brain != nil && row.detail != InstinctApp.toggleDetail ? row.detail : nil
        s.brainPath = brain.map { path($0, home: home) }
        s.canOpenInbox = brain != nil
        s.showsActions = brain != nil
        s.canPause = settings.on
        s.canSweep = settings.on && brain != nil && cleanupInstalled
        s.pausedLine = InstinctApp.pausedLine(until: settings.pausedUntil, now: now, timeZone: timeZone)
        s.isPaused = s.pausedLine != nil
        s.sweepEnabled = s.canSweep && !s.isPaused && !sweeping
        if sweeping { s.sweepTitle = "Reading" }
        if let line = s.pausedLine { s.sweepDetail = line + ". Resume to read now." }
        if s.canSweep {
            s.statusLines = [
                sweeping ? "Reading now" : lastSweepLine(state, now: now, timeZone: timeZone),
                next(last: state.lastSweep, hours: settings.intervalHours, pausedUntil: settings.pausedUntil, now: now, timeZone: timeZone),
                itemsToday == 0 ? "Nothing waiting" : "\(itemsToday) \(itemsToday == 1 ? "item" : "items") waiting",
            ]
            if collected > 0 { s.statusLines.append("\(collected) \(collected == 1 ? "dictation" : "dictations") collected") }
        }
        return s
    }

    /// What the last sweep did, when that is known (F1.40). A meeting sweep has no `lastSweep`, so the result's own time counts.
    private static func lastSweepLine(_ state: InstinctState, now: Date, timeZone: TimeZone) -> String {
        guard let r = state.lastResult else {
            return state.lastSweep.map { "Last sweep " + when($0, now: now, timeZone: timeZone) } ?? "No sweep yet"
        }
        let head = "Last sweep " + when(r.at, now: now, timeZone: timeZone)
        if r.failed { return head + " could not read. Nothing was lost, it tries again soon." }
        guard let read = InstinctApp.readText(meetings: r.meetings, dictations: r.dictations) else { return head + ": nothing new to read" }
        if r.written == 0 { return head + ": read \(read), nothing to propose" }
        return head + ": read \(read), wrote \(r.written) \(r.written == 1 ? "proposal" : "proposals")"
    }

    /// The scheduler's rule (F1.9) in words: the interval after the last sweep, not before the pause ends.
    private static func next(last: Date?, hours: Int, pausedUntil: Date?, now: Date, timeZone: TimeZone) -> String {
        var due = last.map { $0.addingTimeInterval(Double(max(hours, 1)) * 3600) }
        if let until = pausedUntil, until > now { due = max(due ?? until, until) }
        guard let due, due > now else { return "Next sweep soon" }
        return "Next around " + when(due, now: now, timeZone: timeZone)
    }

    /// "12:00", "yesterday 23:00", "tomorrow 01:00" or "3 Nov 12:00".
    static func when(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let time = clock(date, timeZone: timeZone)
        if cal.isDate(date, inSameDayAs: now) { return time }
        if let d = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: d) { return "yesterday " + time }
        if let d = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: d) { return "tomorrow " + time }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "d MMM"
        return f.string(from: date) + " " + time
    }

    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func path(_ url: URL, home: String) -> String {
        let p = url.path
        return p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    /// The excluded apps by name: the default names, then what the system knows, then the bundle id itself.
    static func excludedRows(_ bundles: [String], resolve: (String) -> String?) -> [ExcludedApp] {
        bundles.map { ExcludedApp(bundle: $0, name: InstinctRules.knownAppNames[$0] ?? resolve($0) ?? $0) }
    }
}
