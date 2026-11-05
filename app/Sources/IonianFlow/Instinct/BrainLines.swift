import Foundation

struct BrainProject: Equatable {
    var slug: String
    var description: String
    var focus: String
    var now: [String]
    var open: [String]
}

struct BrainLine: Equatable {
    enum Origin: Equatable { case projectField, log, instinct }
    var text: String
    var project: String?
    var origin: Origin
}

/// Reads what an Instinct item is compared against from an Ionian Brain folder (spec: "Brain lines").
enum BrainLines {
    static let windowDays = 30

    static func isBrain(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        func dir(_ n: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(n).path, isDirectory: &isDir) && isDir.boolValue }
        return fm.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) && dir("inbox") && dir("projects")
    }

    static func projects(in brain: URL) -> [BrainProject] {
        markdownFiles(in: brain.appendingPathComponent("projects")).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let fm = frontmatter(text)
            return BrainProject(slug: url.deletingPathExtension().lastPathComponent,
                                description: fm["description"] ?? "", focus: fm["focus"] ?? "",
                                now: section("Now", in: text), open: section("Open", in: text))
        }
    }

    static func lines(in brain: URL, now: Date, calendar: Calendar = .current) -> [BrainLine] {
        var out: [BrainLine] = []
        let cutoff = dayString(calendar.date(byAdding: .day, value: -windowDays, to: now) ?? now, calendar)
        for p in projects(in: brain) {
            for t in [p.description, p.focus] + p.now + p.open where !t.isEmpty {
                out.append(BrainLine(text: t, project: p.slug, origin: .projectField))
            }
        }
        for url in markdownFiles(in: brain.appendingPathComponent("logs")) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let slug = url.deletingPathExtension().lastPathComponent
            var recent = false
            for raw in text.components(separatedBy: .newlines) {
                if raw.hasPrefix("## ") {
                    let head = raw.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    recent = isDate(head) && head >= cutoff
                } else if recent, let t = listText(raw) {
                    out.append(BrainLine(text: t, project: slug, origin: .log))
                }
            }
        }
        for (folder, limited) in [("inbox", false), ("_archive/inbox", true)] {
            for url in instinctFiles(in: brain.appendingPathComponent(folder)) {
                if limited {
                    guard let d = fileDate(url), d >= cutoff else { continue }
                }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for raw in text.components(separatedBy: .newlines) {
                    if let item = InstinctLineText.parse(raw) { out.append(BrainLine(text: item.text, project: item.project, origin: .instinct)) }
                }
            }
        }
        return out
    }

    // MARK: files

    static func instinctFiles(in dir: URL) -> [URL] {
        markdownFiles(in: dir).filter { $0.lastPathComponent.contains("-instinct") }
    }

    static func fileDate(_ url: URL) -> String? {
        let d = String(url.lastPathComponent.prefix(10))
        return isDate(d) ? d : nil
    }

    private static func markdownFiles(in dir: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: text

    private static func isDate(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 10 else { return false }
        return b.enumerated().allSatisfy { i, c in (i == 4 || i == 7) ? c == 45 : (c >= 48 && c <= 57) }
    }

    private static func dayString(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var out: [String: String] = [:]
        for l in lines[1..<end] {
            guard let colon = l.firstIndex(of: ":"), !l.hasPrefix(" ") else { continue }
            let key = String(l[..<colon])
            out[key] = String(l[l.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return out
    }

    /// Non-empty lines under `## <name>` up to the next `## `, list markers and checkboxes removed.
    private static func section(_ name: String, in text: String) -> [String] {
        var inside = false
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.hasPrefix("## ") { inside = raw.dropFirst(3).trimmingCharacters(in: .whitespaces) == name; continue }
            if inside, let t = listText(raw, requireMarker: false) { out.append(t) }
        }
        return out
    }

    /// The text of a list line without `- `, `* ` and a checkbox; nil for blank lines (and, with a marker required, for non-list lines).
    static func listText(_ raw: String, requireMarker: Bool = true) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s = String(s.dropFirst(2)) } else if requireMarker { return nil }
        if s.hasPrefix("["), s.count >= 3, s[s.index(s.startIndex, offsetBy: 2)] == "]" {
            s = String(s.dropFirst(3))
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

/// One line of an Instinct day file: `- [ ] <category>: <text> (owner/due) → <project> > "<quote>" (...)`.
struct InstinctLineText {
    static let categories = ["todo", "decision", "fact"]
    var mark: Character
    var category: String
    var text: String
    var project: String?

    static func parse(_ raw: String) -> InstinctLineText? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("- ["), s.count > 6 else { return nil }
        let chars = Array(s)
        guard chars[4] == "]", chars[5] == " " else { return nil }
        let rest = String(chars[6...])
        guard let cat = categories.first(where: { rest.hasPrefix($0 + ": ") }) else { return nil }
        let body = String(rest.dropFirst(cat.count + 2))
        var itemText = body
        var project: String?
        if let arrow = body.range(of: " →") {
            itemText = String(body[..<arrow.lowerBound])
            let after = body[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let slug = after.prefix { !$0.isWhitespace }
            project = (slug.isEmpty || slug == "none") ? nil : String(slug)
        }
        itemText = itemText.trimmingCharacters(in: .whitespaces)
        if itemText.hasSuffix(")"), let open = itemText.range(of: " (", options: .backwards) {
            let inner = itemText[open.upperBound...].dropLast()
            if inner.contains("owner:") || inner.contains("due:") { itemText = String(itemText[..<open.lowerBound]) }
        }
        return InstinctLineText(mark: chars[3], category: cat, text: itemText, project: project)
    }
}
