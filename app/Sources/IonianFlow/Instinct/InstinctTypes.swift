import Foundation

enum InstinctCategory: String, Codable, CaseIterable { case todo, decision, fact }
enum InstinctSpeaker: String, Codable { case you = "You", them = "Them" }

struct InstinctSource: Equatable {
    enum Kind: Equatable { case dictation(app: String, bundle: String), transcript(fileName: String) }
    var id: String          // buffer line id, or "<file name>#<block index>"
    var kind: Kind
    var time: Date          // dictation time, or the block's start (frontmatter date + block HH:mm)
    var speaker: InstinctSpeaker?
    var text: String
}

struct InstinctItem: Equatable, Codable {
    var category: InstinctCategory
    var text: String
    var owner: String?
    var due: String?        // YYYY-MM-DD
    var quote: String
    var sourceID: String
    var project: String     // a project slug or "none"
    var confidence: Double
    var conflicts: String?
}

struct InstinctProjectHint: Equatable { var slug: String; var description: String; var focus: String }

enum InstinctVerdict: Equatable { case same, conflicts(String), new }

protocol InstinctModel {
    func extract(_ sources: [InstinctSource], projects: [InstinctProjectHint]) async throws -> [InstinctItem]
    func judge(_ item: InstinctItem, against lines: [String]) async throws -> InstinctVerdict
}

/// Reading the model's answers. Both return nil when the answer does not parse; the caller retries (F1.32).
enum InstinctParsing {
    static func items(_ answer: String) -> [InstinctItem]? {
        guard let obj = object(in: answer), let raw = obj["items"] as? [Any] else { return nil }
        return raw.compactMap { entry -> InstinctItem? in
            guard let d = entry as? [String: Any],
                  let cat = (d["category"] as? String).flatMap(InstinctCategory.init(rawValue:)),
                  let text = d["text"] as? String, let quote = d["quote"] as? String,
                  let source = d["source"] as? String else { return nil }
            let conf = (d["confidence"] as? NSNumber)?.doubleValue ?? 0
            return InstinctItem(category: cat, text: text, owner: d["owner"] as? String, due: d["due"] as? String,
                                quote: quote, sourceID: source, project: (d["project"] as? String) ?? "none",
                                confidence: conf, conflicts: nil)
        }
    }

    static func verdict(_ answer: String) -> InstinctVerdict? {
        guard let obj = object(in: answer), let v = obj["verdict"] as? String else { return nil }
        switch v {
        case "same": return .same
        case "new": return .new
        case "conflicts": return (obj["line"] as? String).map { .conflicts($0) }
        default: return nil
        }
    }

    /// F1.19: the quote occurs in the source text, whitespace collapsed, case ignored.
    static func isVerbatim(_ quote: String, in text: String) -> Bool {
        let q = normalize(quote)
        return !q.isEmpty && normalize(text).contains(q)
    }

    private static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The first top-level JSON object in the answer, tolerating prose or a code fence around it.
    private static func object(in answer: String) -> [String: Any]? {
        let chars = Array(answer)
        var i = 0
        while i < chars.count {
            if chars[i] == "{", let end = matching(chars, from: i) {
                let slice = String(chars[i...end])
                if let d = slice.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
            }
            i += 1
        }
        return nil
    }

    private static func matching(_ c: [Character], from start: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        for i in start..<c.count {
            let ch = c[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }
}
