import Foundation

/// The settings the Aware page's top part depends on.
struct AwarePageSettings: Equatable {
    var on: Bool
}

/// Copy of the Aware page (F3). Calm, no hype.
enum AwarePage {
    static let headline = "It keeps what matters."
    static let lead = "Flow reads your finished meetings on this Mac and proposes to-dos, decisions and facts to your brain."
    static let kindLines: [(AwareCategory, String)] = [
        (.todo, "Things you or someone else agreed to do."),
        (.decision, "Choices that were settled."),
        (.fact, "Names, numbers and dates worth keeping."),
    ]
    static let kindTitles: [AwareCategory: String] = [.todo: "To-dos", .decision: "Decisions", .fact: "Facts"]
    static let sweepDetail = "Read waiting meetings now."
    static let noBrainPath = "No Brain connected yet"
    static let pitch = "Say it in a meeting. Aware keeps the to-dos, decisions and facts."

    /// Every sentence that is not built from data, for the copy test.
    static var otherCopy: [String] {
        [sweepDetail, noBrainPath, pitch, lead, AwareApp.notABrain,
         AwareApp.getBrainPill, AwareApp.connectBrainTitle, AwareApp.noBrainDetail, AwareApp.noModelDetail, AwareApp.toggleDetail]
    }
}

/// What the Aware page shows, from the settings, the brain, the model, the state file, the clock and
/// today's item count (F3.2, F3.12). No SwiftUI.
struct AwarePageState: Equatable {
    var switchOn = false
    /// No Brain: the top section invites with the one ink pill and a link to connect one (F3.15).
    var invite = false
    /// The cleanup model is missing: one plain sentence (F3.12).
    var problem: String?
    /// Last sweep, meetings waiting, items waiting; empty while off or blocked.
    var statusLines: [String] = []
    var brainPath: String?
    var canOpenInbox = false
    /// The actions only exist with a Brain; there is nothing to sweep before.
    var showsActions = false
    var canSweep = false
    /// The Sweep now button: off while already reading.
    var sweepEnabled = false
    var sweepTitle = "Sweep now"
    var sweepDetail = AwarePage.sweepDetail

    static func make(settings: AwarePageSettings, brain: URL?, cleanupInstalled: Bool, state: AwareState,
                     now: Date, itemsToday: Int, pending: Int = 0, sweeping: Bool = false,
                     home: String = NSHomeDirectory(), timeZone: TimeZone = .current) -> AwarePageState {
        let row = AwareApp.row(brainFound: brain != nil, on: settings.on, cleanupInstalled: cleanupInstalled)
        var s = AwarePageState()
        s.switchOn = row.shownOn
        s.invite = brain == nil
        s.problem = brain != nil && row.detail != AwareApp.toggleDetail ? row.detail : nil
        s.brainPath = brain.map { path($0, home: home) }
        s.canOpenInbox = brain != nil
        s.showsActions = brain != nil
        s.canSweep = settings.on && brain != nil && cleanupInstalled
        s.sweepEnabled = s.canSweep && !sweeping
        if sweeping { s.sweepTitle = "Reading" }
        if s.canSweep {
            s.statusLines = [sweeping ? "Reading now" : lastSweepLine(state, now: now, timeZone: timeZone)]
            if pending > 0 { s.statusLines.append("\(pending) \(pending == 1 ? "meeting" : "meetings") waiting") }
            s.statusLines.append(itemsToday == 0 ? "Nothing waiting" : "\(itemsToday) \(itemsToday == 1 ? "item" : "items") waiting")
        }
        return s
    }

    /// What the last sweep did, when that is known (F1.40). 
    private static func lastSweepLine(_ state: AwareState, now: Date, timeZone: TimeZone) -> String {
        guard let r = state.lastResult else { return "No sweep yet" }
        let head = "Last sweep " + when(r.at, now: now, timeZone: timeZone)
        if r.failed { return head + " could not read. Nothing was lost, it tries again soon." }
        guard let read = AwareApp.readText(meetings: r.meetings) else { return head + ": nothing new to read" }
        if r.written == 0 { return head + ": read \(read), nothing to propose" }
        return head + ": read \(read), wrote \(r.written) \(r.written == 1 ? "proposal" : "proposals")"
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
}
