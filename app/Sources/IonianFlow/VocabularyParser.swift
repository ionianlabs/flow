import Foundation

/// One line of the vocabulary file, parsed. The format and the Python parser are in the former Python vocab.py;
/// keep the two in step (VocabNormalizer's selftest compares them on the same inputs).
struct VocabTerm: Equatable {
    let text: String
    let category: String
    let isVault: Bool
    let aliases: [String]
    let line: Int
}

struct ParsedVocabulary {
    var domain = ""
    var domainLine: Int?
    var terms: [VocabTerm] = []  // manual first, then the vault's ranking, in file order
    var ignored: [String] = []
}

enum VocabularyParser {
    static let start = "<!-- ionian-flow:vault:start", end = "<!-- ionian-flow:vault:end -->"
    static let oldStart = "<!-- openflow:vault:start", oldEnd = "<!-- openflow:vault:end -->"  // still read, never written
    static func isStart(_ s: String) -> Bool { s.hasPrefix(start) || s.hasPrefix(oldStart) }
    static func isEnd(_ s: String) -> Bool { s.hasPrefix(end) || s.hasPrefix(oldEnd) }

    private static let heardAs = try! NSRegularExpression(pattern: #"\s*\(heard as:\s*(.*?)\)\s*$"#, options: .caseInsensitive)

    /// Python's str.splitlines separators (the file may come with CRLF or from another editor).
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = [], cur = String.UnicodeScalarView(), prevCR = false
        for u in text.unicodeScalars {
            if prevCR { prevCR = false; if u == "\n" { continue } }
            switch u.value {
            case 0x0D: lines.append(String(cur)); cur = .init(); prevCR = true
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029: lines.append(String(cur)); cur = .init()
            default: cur.append(u)
            }
        }
        if !cur.isEmpty { lines.append(String(cur)) }
        return lines
    }

    static func parse(_ markdown: String) -> ParsedVocabulary { parse(lines: splitLines(markdown)) }

    static func parse(lines: [String]) -> ParsedVocabulary {
        var out = ParsedVocabulary()
        var seen = Set<String>(), ignoredKeys = Set<String>()
        var inBlock = false
        var category: String?
        for (i, raw) in lines.enumerated() {
            let s = raw.pyStrip
            if isStart(s) { inBlock = true; category = nil; continue }
            if isEnd(s) { inBlock = false; category = nil; continue }
            // An empty Domain line doesn't count: a later one can still fill it.
            if !inBlock, out.domain.isEmpty, s.lowercased().hasPrefix("domain:") {
                out.domain = String(s.dropFirst(7)).pyStrip
                if out.domainLine == nil || !out.domain.isEmpty { out.domainLine = i }
                continue
            }
            if inBlock, s.hasPrefix("### ") { category = String(s.dropFirst(4)).pyStrip; continue }
            if s.hasPrefix("## ") { category = inBlock ? nil : String(s.dropFirst(3)).pyStrip; continue }
            if s.hasPrefix("#") { if !inBlock { category = nil }; continue }
            guard let cat = category, let body = bulletBody(s) else { continue }
            var text = body
            var aliases: [String] = []
            let ns = text as NSString
            if let m = heardAs.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                aliases = ns.substring(with: m.range(at: 1)).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.pyStrip }.filter { !$0.isEmpty }
                text = ns.substring(to: m.range.location).pyStrip
            }
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            if !inBlock, cat.lowercased() == "ignore" {
                out.ignored.append(text)
                ignoredKeys.insert(key)
            } else if !seen.contains(key) {
                seen.insert(key)
                out.terms.append(VocabTerm(text: text, category: cat, isVault: inBlock, aliases: aliases, line: i))
            }
        }
        // Ignore only overrides the vault: a term you listed yourself stays.
        out.terms.removeAll { $0.isVault && ignoredKeys.contains($0.text.lowercased()) }
        return out
    }

    /// "- text" or "* text" (any whitespace after the marker), the line already stripped.
    private static func bulletBody(_ s: String) -> String? {
        guard let first = s.unicodeScalars.first, first == "-" || first == "*" else { return nil }
        let rest = s.unicodeScalars.dropFirst()
        guard let sp = rest.first, sp.isPySpace else { return nil }
        let body = String(rest).pyStrip
        return body.isEmpty ? nil : body
    }
}

// MARK: Vault block

enum VocabularyFile {
    static let template = """
        # Ionian Flow Vocabulary

        Domain:

        Words Ionian Flow should recognize: names, acronyms, product and project words. One per line.
        To fix a spelling, add what the recognizer writes instead as "(heard as: wrong spelling)".
        Changes apply to the next dictation.

        ## Terms

        ## People

        ## Ignore

        """

    /// Rewrites only the vault block (appended if missing); `domain` fills an empty Domain line,
    /// once there is one it's yours. The old openflow markers are upgraded. Atomic.
    static func writeVaultBlock(to url: URL, groups: [(category: String, terms: [String])], heading: String, domain: String = "") throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? template
        var lines = ["\(VocabularyParser.start)  Regenerated by Ionian Flow's vault scan. Move a line above to keep it. -->", "## \(heading)"]
        for g in groups where !g.terms.isEmpty {
            lines += ["", "### \(g.category)"] + g.terms.map { "- \($0)" }
        }
        lines.append(VocabularyParser.end)
        let block = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: VocabularyParser.oldStart, with: VocabularyParser.start)
            .replacingOccurrences(of: VocabularyParser.oldEnd, with: VocabularyParser.end)
        if let s = text.range(of: VocabularyParser.start), let e = text.range(of: VocabularyParser.end), e.lowerBound > s.lowerBound {
            text = String(text[..<s.lowerBound]) + block + String(text[e.upperBound...])
        } else {
            while text.hasSuffix("\n") { text.removeLast() }
            text += "\n\n" + block + "\n"
        }
        if !domain.isEmpty, let r = text.range(of: #"(?m)^Domain:[ \t]*$"#, options: .regularExpression) {
            text.replaceSubrange(r, with: "Domain: \(domain)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: Python string semantics

extension Unicode.Scalar {
    /// str.isspace(): what Python's strip, split and \s treat as whitespace.
    var isPySpace: Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }
}

extension StringProtocol {
    var pyStrip: String {
        let u = Array(unicodeScalars)
        var a = 0, b = u.count
        while a < b, u[a].isPySpace { a += 1 }
        while b > a, u[b - 1].isPySpace { b -= 1 }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: u[a..<b])
        return String(v)
    }
}
