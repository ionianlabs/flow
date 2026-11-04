import Foundation

/// What the LLM wrote about a finished transcript (the former Python polish.py `summarize`).
struct TranscriptSummary: Equatable {
    var description: String
    var tags: [String]
    var keywords: [String]
    var points: [String]
    var decisions: [String]
    var actions: [String]

    /// From the server's "summary" message; nil when it has neither a description nor points.
    init?(_ obj: [String: Any]) {
        let list = { (key: String) in (obj[key] as? [Any] ?? []).compactMap { $0 as? String } }
        description = obj["description"] as? String ?? ""
        tags = list("tags")
        keywords = list("keywords")
        points = list("points")
        decisions = list("decisions")
        actions = list("actions")
        if description.isEmpty && points.isEmpty { return nil }
    }
}

/// Tags the notes in the vault already use, most frequent first: the summary picks from these
/// before it invents one. Hidden folders (".obsidian", ".confidential", ...) are skipped.
enum VaultTags {
    /// The vault set in Ionian Flow, else the folder holding ".obsidian" above the transcripts folder.
    static func root() -> URL? {
        if let vault = Settings.vault { return vault }
        var dir = Settings.transcriptsFolder
        while dir.pathComponents.count > 2 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".obsidian").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func common(limit: Int = 40) -> [String] {
        guard let root = root(), let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var counts: [String: Int] = [:]
        var seen = 0
        for case let url as URL in files where url.pathExtension == "md" {
            seen += 1
            if seen > 5_000 { break }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = String(decoding: handle.readData(ofLength: 4_096), as: UTF8.self)
            try? handle.close()
            for tag in tags(inFrontmatter: head) { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// `tags: [a, b]` or a `tags:` list of `- a` lines, in the frontmatter at the top of a note.
    static func tags(inFrontmatter text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        let clean = { (s: Substring) in s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")).lowercased() }
        for (i, line) in lines[1..<end].enumerated() where line.hasPrefix("tags:") {
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") {
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map(clean).filter { !$0.isEmpty }
            }
            return lines[(i + 2)..<end].prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
                .map { clean($0.trimmingCharacters(in: .whitespaces).dropFirst(2)) }.filter { !$0.isEmpty }
        }
        return []
    }
}
