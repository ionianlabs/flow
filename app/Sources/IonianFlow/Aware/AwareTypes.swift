import Foundation

enum AwareCategory: String, Codable, CaseIterable { case todo, decision, fact }
enum AwareSpeaker: String, Codable { case you = "You", them = "Them" }

struct AwareSource: Equatable {
    enum Kind: Equatable { case dictation(app: String, bundle: String), transcript(fileName: String) }
    var id: String          // buffer line id, or "<file name>#<block index>"
    var kind: Kind
    var time: Date          // dictation time, or the block's start (frontmatter date + block HH:mm)
    var speaker: AwareSpeaker?
    var text: String
}

struct AwareItem: Equatable, Codable {
    var category: AwareCategory
    var text: String
    var owner: String?
    var due: String?        // YYYY-MM-DD
    var quote: String
    var sourceID: String
    var project: String     // a project slug or "none"
    var confidence: Double
    var conflicts: String?
}

struct AwareProjectHint: Equatable { var slug: String; var description: String; var focus: String }

enum AwareVerdict: Equatable { case same, conflicts(String), new }

/// The strict second look at one candidate: does its quote hold a to-do, a settled decision or a lasting fact,
/// and does it belong to the suggested project.
struct AwareVerification: Equatable {
    var holds: Bool
    var belongsToProject: Bool
}

protocol AwareModel {
    func extract(_ sources: [AwareSource], projects: [AwareProjectHint]) async throws -> [AwareItem]
    func judge(_ item: AwareItem, against lines: [String]) async throws -> AwareVerdict
    /// `project` is the item's project, nil when it has none.
    func verify(_ item: AwareItem, speaker: AwareSpeaker?, project: AwareProjectHint?) async throws -> AwareVerification
}

/// Reading the model's answers. Both return nil when the answer does not parse; the caller retries (F1.32).
enum AwareParsing {
    static func items(_ answer: String) -> [AwareItem]? {
        guard let obj = object(in: answer), let raw = obj["items"] as? [Any] else { return nil }
        return raw.compactMap { entry -> AwareItem? in
            guard let d = entry as? [String: Any],
                  let cat = (d["category"] as? String).flatMap(AwareCategory.init(rawValue:)),
                  let text = d["text"] as? String, let quote = d["quote"] as? String,
                  let source = d["source"] as? String else { return nil }
            let conf = (d["confidence"] as? NSNumber)?.doubleValue ?? 0
            return AwareItem(category: cat, text: text, owner: d["owner"] as? String, due: d["due"] as? String,
                                quote: quote, sourceID: source, project: (d["project"] as? String) ?? "none",
                                confidence: conf, conflicts: nil)
        }
    }

    static func verdict(_ answer: String) -> AwareVerdict? {
        guard let obj = object(in: answer), let v = obj["verdict"] as? String else { return nil }
        switch v {
        case "same": return .same
        case "new": return .new
        case "conflicts": return (obj["line"] as? String).map { .conflicts($0) }
        default: return nil
        }
    }

    static func verification(_ answer: String) -> AwareVerification? {
        guard let obj = object(in: answer), let keep = yesNo(obj["keep"]) else { return nil }
        return AwareVerification(holds: keep, belongsToProject: yesNo(obj["project"]) ?? false)
    }

    private static func yesNo(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        switch (v as? String)?.lowercased() { case "yes"?, "true"?: return true; case "no"?, "false"?: return false; default: return nil }
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
