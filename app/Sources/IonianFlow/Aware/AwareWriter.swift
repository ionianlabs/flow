import Foundation

/// How many candidates a sweep dropped, by reason (the footer line of a day-file section).
struct AwareDropCounts: Equatable {
    var byRules = 0, noProject = 0, lowConfidence = 0, duplicate = 0, quoteNotFound = 0, unreadable = 0, belowCut = 0
}

enum AwareSweepKind { case scheduled, meeting }

/// Creates or appends `inbox/YYYY-MM-DD-aware.md` (F1.29, F1.30). Every path is injected.
struct AwareWriter {
    struct Entry: Equatable {
        var item: AwareItem
        var source: AwareSource
    }

    var brainRoot: URL
    var transcriptsFolder: URL
    var timeZone: TimeZone = .current

    func fileURL(on date: Date) -> URL {
        brainRoot.appendingPathComponent("inbox/\(fmt(date, "yyyy-MM-dd"))-aware.md")
    }

    /// Items already in the day file, for the daily cap (F1.28).
    func itemsToday(on date: Date) -> Int {
        guard let text = try? String(contentsOf: fileURL(on: date), encoding: .utf8) else { return 0 }
        return Self.itemLines(text)
    }

    /// Writes one section and returns the file, or nil (nothing written) when there are no items (F1.30).
    @discardableResult
    func write(at date: Date, kind: AwareSweepKind, entries: [Entry], meetings: Int, dictations: Int,
               dropped: AwareDropCounts) throws -> URL? {
        guard !entries.isEmpty else { return nil }
        let url = fileURL(on: date)
        let day = fmt(date, "yyyy-MM-dd")
        var section = ["## " + fmt(date, "HH:mm") + (kind == .meeting ? " meeting" : "")]
        section += entries.map(line)
        section += ["", footer(meetings: meetings, dictations: dictations, dropped: dropped)]

        var text: String
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            text = existing + (existing.hasSuffix("\n") ? "" : "\n") + "\n" + section.joined(separator: "\n") + "\n"
        } else {
            text = """
            ---
            type: capture
            description: ""
            tags: [automation]
            org: unknown
            source: flow
            updated: \(day)
            ---

            # Aware \(day)

            Mark each line: [x] accept, [~] edited, [-] reject, [=] duplicate.


            """ + section.joined(separator: "\n") + "\n"
            text = text.replacingOccurrences(of: "\n\n\n## ", with: "\n\n## ")
        }
        text = Self.setFrontmatter(text, description: Self.description(text), updated: day)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Format

    private func line(_ e: Entry) -> String {
        let i = e.item
        var parts: [String] = []
        if let o = i.owner { parts.append("owner: \(o)") }
        if let d = i.due { parts.append("due: \(d)") }
        let meta = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        let quote = i.quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = "- [ ] \(i.category.rawValue): \(i.text)\(meta) → \(i.project) > \"\(quote)\" (\(sourceText(e.source)), "
        if let s = e.source.speaker { out += "\(s.rawValue), " }
        out += String(format: "%.2f", i.confidence) + ")"
        if let c = i.conflicts { out += " conflicts: \"\(c)\"" }
        return out
    }

    private func sourceText(_ s: AwareSource) -> String {
        switch s.kind {
        case .dictation(let app, _):
            return "\(app) \(fmt(s.time, "yyyy-MM-dd HH:mm"))"
        case .transcript(let name):
            let time = fmt(s.time, "HH:mm")
            let file = transcriptsFolder.appendingPathComponent(name)
            let root = brainRoot.resolvingSymlinksInPath().path
            let path = file.resolvingSymlinksInPath().path
            if path.hasPrefix(root + "/") {
                let rel = String(path.dropFirst(root.count))
                let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
                let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
                return "[\(stem)](\(enc)) \(time)"
            }
            return "\(name) \(time)"
        }
    }

    private func footer(meetings: Int, dictations: Int, dropped d: AwareDropCounts) -> String {
        "Swept \(meetings) \(meetings == 1 ? "meeting" : "meetings"), \(dictations) \(dictations == 1 ? "dictation" : "dictations"). "
            + "Dropped: \(d.byRules) by rules, \(d.noProject) no project, \(d.lowConfidence) low confidence, "
            + "\(d.duplicate) duplicate, \(d.quoteNotFound) quote not found, \(d.unreadable) unreadable, \(d.belowCut) below the cut."
    }

    // MARK: Reading the file back

    private static func itemLines(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter {
            $0.range(of: #"^- \[.\] "#, options: .regularExpression) != nil
        }.count
    }

    /// "Aware: 4 items from 1 meeting and 12 dictations": items, and the sources summed from the section footers.
    private static func description(_ text: String) -> String {
        var meetings = 0, dictations = 0
        for l in text.components(separatedBy: "\n") where l.hasPrefix("Swept ") {
            let re = try! NSRegularExpression(pattern: #"^Swept (\d+) meetings?, (\d+) dictations?\."#)
            let ns = l as NSString
            if let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                meetings += Int(ns.substring(with: m.range(at: 1))) ?? 0
                dictations += Int(ns.substring(with: m.range(at: 2))) ?? 0
            }
        }
        let n = itemLines(text)
        return "Aware: \(n) \(n == 1 ? "item" : "items") from \(meetings) \(meetings == 1 ? "meeting" : "meetings") and \(dictations) \(dictations == 1 ? "dictation" : "dictations")"
    }

    private static func setFrontmatter(_ text: String, description: String, updated: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        for i in 1..<close {
            if lines[i].hasPrefix("description:") { lines[i] = "description: \"\(description)\"" }
            if lines[i].hasPrefix("updated:") { lines[i] = "updated: \(updated)" }
        }
        return lines.joined(separator: "\n")
    }

    private func fmt(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
