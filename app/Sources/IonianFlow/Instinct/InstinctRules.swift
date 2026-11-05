import Foundation

/// Constants and pure rules of Instinct (spec F1.2 to F1.4, F1.15, F1.20 to F1.22, F1.27).
/// Thresholds are constants like `SweepRank.minScore`, to be tuned from the precision report.
enum InstinctRules {
    /// Why an item or dictation was dropped; the raw value is the label the footer counts.
    enum DropReason: String, Equatable {
        case tooShort = "too short"
        case codeAppNoCue = "code app, no cue"
        case noProject = "no project"
        case lowConfidence = "low confidence"
    }

    // MARK: capture (F1.2 to F1.4)

    static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.Passwords", "com.apple.keychainaccess",
    ]

    static func shouldCapture(bundle: String, excluded: [String], secureInput: Bool, pausedUntil: Date?, now: Date) -> Bool {
        if excluded.contains(bundle) || secureInput { return false }
        if let until = pausedUntil, now < until { return false }
        return true
    }

    // MARK: dictation prefilter (F1.15)

    static let minWords = 3
    static let codeApps = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ]
    static let cues = [
        "todo", "to do", "remind me", "note to self", "don't forget", "I need to", "we decided", "for the record",
        "erinner mich", "nicht vergessen", "wir haben entschieden",
    ]

    /// Order of F1.15: too short, then code app without cue; nil means the dictation goes to the model.
    static func prefilter(text: String, bundle: String) -> DropReason? {
        if text.split(whereSeparator: { $0.isWhitespace }).count < minWords { return .tooShort }
        if codeApps.contains(bundle), !hasCue(text) { return .codeAppNoCue }
        return nil
    }

    /// Whole words or phrases, ignoring case; the typographic apostrophe counts as the plain one.
    static func hasCue(_ text: String) -> Bool {
        let hay = " " + cueTokens(text).joined(separator: " ") + " "
        return cues.contains { hay.contains(" " + cueTokens($0).joined(separator: " ") + " ") }
    }

    private static func cueTokens(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    // MARK: relevance gate (F1.20, F1.21)

    static let todoFloor = 0.5
    static let knowledgeFloor = 0.7

    /// nil means the item passes. Project "none" is allowed for to-dos only.
    static func gate(kind: String, project: String, confidence: Double) -> DropReason? {
        let isTodo = kind.lowercased() == "todo"
        if !isTodo, project.trimmingCharacters(in: .whitespaces).lowercased() == "none" { return .noProject }
        if confidence < (isTodo ? todoFloor : knowledgeFloor) { return .lowConfidence }
        return nil
    }

    // MARK: duplicate overlap (F1.22)

    static let overlapThreshold = 0.6
    static let overlapCandidates = 20

    static func contentWords(_ text: String) -> Set<String> {
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        return Set(words.filter { !stopWords.contains($0) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// The brain lines with the highest overlap with the item (at most 20, zero overlap left out, ties in line order),
    /// and whether any reaches the threshold.
    static func rankByOverlap(item: String, lines: [String]) -> (top: [(line: String, score: Double)], duplicate: Bool) {
        let words = contentWords(item)
        typealias Row = (index: Int, line: String, score: Double)
        var rows: [Row] = []
        for (index, line) in lines.enumerated() {
            let score = jaccard(words, contentWords(line))
            if score > 0 { rows.append((index: index, line: line, score: score)) }
        }
        rows.sort { (x: Row, y: Row) -> Bool in x.score != y.score ? x.score > y.score : x.index < y.index }
        var top: [(line: String, score: Double)] = []
        for row in rows.prefix(overlapCandidates) { top.append((line: row.line, score: row.score)) }
        let duplicate = top.contains { (r: (line: String, score: Double)) -> Bool in r.score >= overlapThreshold }
        return (top, duplicate)
    }

    // MARK: due date year (the model only sees weekdays and months)

    private static let monthWords: Set<String> = [
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "may",
        "januar", "februar", "märz", "mai", "juni", "juli", "oktober", "dezember",
    ]

    /// A due date before the day of its source, said as month and day with no year, is meant for the next year:
    /// it moves one year ahead. Anything else stays as it is.
    static func rolledDue(_ due: String?, quote: String, sourceTime: Date, calendar: Calendar = .current) -> String? {
        guard let due else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: due), date < calendar.startOfDay(for: sourceTime) else { return due }
        let words = cueTokens(quote)
        guard words.contains(where: { monthWords.contains($0) }),
              !words.contains(where: { $0.count == 4 && $0.allSatisfy(\.isNumber) && $0.hasPrefix("20") }),
              let next = calendar.date(byAdding: .year, value: 1, to: date) else { return due }
        return f.string(from: next)
    }

    // MARK: chunks (the parts the model reads)

    /// A small model keeps its focus on short parts: at most this many characters and sources per model call.
    static let chunkLimit = 1_500
    static let chunkMaxSources = 12

    /// Groups sources, in order and never split, into parts of at most `limit` characters of text and `maxSources` sources.
    static func chunks(_ sources: [InstinctSource], limit: Int = chunkLimit, maxSources: Int = chunkMaxSources) -> [[InstinctSource]] {
        var parts: [[InstinctSource]] = [], cur: [InstinctSource] = [], size = 0
        for s in sources {
            if !cur.isEmpty && (size + s.text.count > limit || cur.count >= maxSources) { parts.append(cur); cur = []; size = 0 }
            cur.append(s); size += s.text.count
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts
    }

    // MARK: caps (F1.27)

    static let perSweepCap = 10
    static let perDayCap = 25

    /// Keeps the `limit` most confident entries in their original order (ties: the earlier one); `cut` is how many were left out.
    static func keepHighestConfidence<T>(_ items: [T], limit: Int, confidence: (T) -> Double) -> (kept: [T], cut: Int) {
        guard items.count > limit else { return (items, 0) }
        let scored: [(offset: Int, conf: Double)] = items.enumerated().map { (offset: $0.offset, conf: confidence($0.element)) }
        let ranked = scored.sorted { (x: (offset: Int, conf: Double), y: (offset: Int, conf: Double)) -> Bool in
            x.conf != y.conf ? x.conf > y.conf : x.offset < y.offset
        }
        let keep = Set(ranked.prefix(max(limit, 0)).map { $0.offset })
        let kept = items.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        return (kept, items.count - kept.count)
    }

    // MARK: stop words (English and German, fixed; negations are kept as content words)

    static let stopWords: Set<String> = Set(("""
        a an the and or but if then so because as of at by for with about against between into through during
        before after above below to from up down in out on off over under again here there when where
        why how all any both each few more most other some such only own same than too very can will just should now
        is are was were be been being have has had having do does did doing would could might must may i me my
        myself we our ours us you your yours he him his she her hers it its they them their theirs what which who
        whom this that these those am s t re ve ll d also get got let need please while until via
        der die das den dem des ein eine einen einem einer eines und oder aber denn weil wenn dann als wie wo was wer
        wen wem ich mich mir du dich dir er ihn ihm sie ihr ihnen es wir uns euch mein meine meinen dein deine sein
        seine unser unsere ist sind war waren bin bist  wird werden wurde wurden hat haben hatte hatten habe
        kann können muss müssen soll sollen will wollen darf dürfen zu zum zur von vom mit bei nach aus auf an am im
        in um für über unter vor bis durch gegen ohne auch noch schon nur sehr hier da so doch mal dass ob man
        diese dieser dieses jetzt bitte
    """).split(whereSeparator: { $0.isWhitespace }).map(String.init))
}
