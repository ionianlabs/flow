import Foundation

/// Finished meeting transcripts that Aware has not swept yet, and their speaker blocks.
enum TranscriptSource {
    struct Pending: Equatable {
        var toRead: [URL] = []
        var recordAsSwept: [String] = []   // file names older than enabledAt (F1.35)
        /// What the scheduler checks (F1.42): files to read plus files to record as swept.
        var forScheduler: Int { toRead.count + recordAsSwept.count }
        /// What the page shows as waiting: only meetings still to be read, never old ones recorded unread.
        var forPage: Int { toRead.count }
    }

    /// Flat `*.md` files in `folder` (F1.12). Swept files are never read again (F1.14); confidential and
    /// `aware: false` files are skipped silently (F1.13); older than `enabledAt` are recorded unread (F1.35).
    static func pending(in folder: URL, state: AwareState, timeZone: TimeZone = .current) -> Pending {
        var out = Pending()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !state.swept.contains($0) }.sorted()
        for name in names {
            let url = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fm = frontmatter(text)
            guard fm["end"] != nil else { continue }
            if fm["confidential"] == "true" || fm["aware"] == "false" { continue }
            // The file only stores the minute: a meeting started in the minute Aware was turned on counts as after it (F1.39).
            if let enabled = state.enabledAt, let started = startDate(fm, timeZone), started.addingTimeInterval(60) <= enabled {
                out.recordAsSwept.append(name)
            } else {
                out.toRead.append(url)
            }
        }
        return out
    }

    static func parse(fileURL: URL, timeZone: TimeZone = .current) -> [AwareSource] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return parse(text: text, fileName: fileURL.lastPathComponent, timeZone: timeZone)
    }

    /// Blocks are `**You** · 09:17` or `**Them** · 10:14` followed by text up to the next block or heading.
    /// Everything under `## Summary` is ignored.
    static func parse(text: String, fileName: String, timeZone: TimeZone = .current) -> [AwareSource] {
        let fm = frontmatter(text)
        guard let date = fm["date"] else { return [] }
        var out: [AwareSource] = []
        var inSummary = false
        var current: (speaker: AwareSpeaker, time: Date, lines: [String])?
        func flush() {
            guard let c = current else { return }
            let body = c.lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            out.append(AwareSource(id: "\(fileName)#\(out.count)", kind: .transcript(fileName: fileName),
                                      time: c.time, speaker: c.speaker, text: body))
            current = nil
        }
        for line in body(of: text) {
            if line.hasPrefix("#") {
                flush()
                inSummary = line.trimmingCharacters(in: .whitespaces) == "## Summary"
                continue
            }
            if inSummary { continue }
            if let (speaker, hhmm) = header(line) {
                flush()
                if let t = parseDate("\(date) \(hhmm)", timeZone) { current = (speaker, t, []) }
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        flush()
        return out
    }

    private static func header(_ line: String) -> (AwareSpeaker, String)? {
        let l = line.trimmingCharacters(in: .whitespaces)
        for s in [AwareSpeaker.you, .them] {
            let prefix = "**\(s.rawValue)** · "
            if l.hasPrefix(prefix) {
                let t = String(l.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if t.count == 5, t[t.index(t.startIndex, offsetBy: 2)] == ":" { return (s, t) }
            }
        }
        return nil
    }

    private static func body(of text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return lines }
        return Array(lines[(close + 1)...])
    }

    /// Flat `key: value` lines of the frontmatter, quotes stripped.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var out: [String: String] = [:]
        for l in lines[1..<close] {
            guard let colon = l.firstIndex(of: ":"), !l.hasPrefix(" ") else { continue }
            let key = String(l[..<colon]).trimmingCharacters(in: .whitespaces)
            var v = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            out[key] = v
        }
        return out
    }

    private static func startDate(_ fm: [String: String], _ tz: TimeZone) -> Date? {
        guard let d = fm["date"], let s = fm["start"] else { return nil }
        return parseDate("\(d) \(s)", tz)
    }

    private static func parseDate(_ s: String, _ tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)
    }
}
