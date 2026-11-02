import Foundation

/// Writes terms the way the vocabulary does; the port of Vocabulary.normalize in asr/vocab.py,
/// which has the reasoning. "pool request" (an alias) becomes "pull request", spelling variants
/// of rare terms are fixed ("data garage", "Net vora", "E T L"), near misses too, by spelling or
/// sound ("Netfora", "Jana Waber"). Common words are left alone.
final class VocabNormalizer {
    private let aliasRule: (regex: NSRegularExpression, replacement: [String: String])?
    private let spellingRule: (regex: NSRegularExpression, spellings: [String: (term: String, own: [String])])?
    private let fuzzy: FuzzyTerms
    private let freq: WordFrequency

    convenience init(_ vocabulary: ParsedVocabulary, frequency: WordFrequency = WordFrequencyTable.shared) {
        self.init(terms: vocabulary.terms, frequency: frequency)
    }

    convenience init(markdown: String, frequency: WordFrequency = WordFrequencyTable.shared) {
        self.init(VocabularyParser.parse(markdown), frequency: frequency)
    }

    init(terms: [VocabTerm], frequency: WordFrequency) {
        freq = frequency

        // Aliases: "heard as" spellings, longest first. Later terms win a duplicate.
        var aliases: [String: String] = [:], order: [String] = []
        for t in terms {
            for a in t.aliases where !a.isEmpty {
                let k = a.lowercased()
                if aliases[k] == nil { order.append(k) }
                aliases[k] = t.text
            }
        }
        if !aliases.isEmpty {
            let alts = Self.longestFirst(order).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            aliasRule = (try! NSRegularExpression(pattern: #"(?<!\w)("# + alts + #")(?!\w)"#, options: .caseInsensitive), aliases)
        } else {
            aliasRule = nil
        }

        // Spelling variants of rare terms: each character, optionally separated by a space or hyphen.
        var spellings: [String: (term: String, own: [String])] = [:], keys: [String] = []
        for t in terms {
            let parts = Self.sepSplit(t.text.pyStrip)
            if parts.count == 1, freq.common(parts[0]) { continue }  // "ACE" must not rewrite "ace"
            let key = String(String.UnicodeScalarView(t.text.lowercased().unicodeScalars.filter { !Self.isSep($0) }))
            if spellings[key] != nil || key.unicodeScalars.count < 2 { continue }
            spellings[key] = (t.text, parts.map { $0.lowercased() })
            keys.append(key)
        }
        if keys.isEmpty {
            spellingRule = nil
        } else {
            let patterns = Self.longestFirst(keys).map { key in
                key.unicodeScalars.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\s-]?"#)
            }
            spellingRule = (try! NSRegularExpression(pattern: #"(?<!\w)(?:"# + patterns.joined(separator: "|") + #")(?!\w)"#, options: .caseInsensitive), spellings)
        }
        fuzzy = FuzzyTerms(terms: terms, frequency: frequency)
    }

    func normalize(_ text: String) -> String {
        var text = text
        if let r = aliasRule {
            text = Self.sub(r.regex, in: text) { r.replacement[$0.lowercased()] ?? $0 }
        }
        if let r = spellingRule {
            text = Self.sub(r.regex, in: text) { found in
                guard let (term, own) = r.spellings[String(String.UnicodeScalarView(found.lowercased().unicodeScalars.filter { !Self.isSep($0) }))] else { return found }
                let words = Self.sepSplit(found).map { $0.lowercased() }
                if words != own, words.count > 1 {
                    let spelled = words.allSatisfy { $0.unicodeScalars.count == 1 } && Self.isUpper(term)  // "E T L" -> "ETL"
                    if !spelled, words.allSatisfy({ freq.common($0) }) { return found }  // "an open flow" stays
                }
                return term
            }
        }
        return fuzzy.fix(text)
    }

    // MARK: Helpers

    static func isSep(_ u: Unicode.Scalar) -> Bool { u == "-" || u.isPySpace }

    /// re.split(r"[\s-]+", s): empty strings at the ends stay, as in Python.
    static func sepSplit(_ s: String) -> [String] {
        var parts: [String] = [], cur = String.UnicodeScalarView(), inSep = false
        for u in s.unicodeScalars {
            if isSep(u) {
                if !inSep { parts.append(String(cur)); cur = .init(); inSep = true }
            } else { inSep = false; cur.append(u) }
        }
        parts.append(String(cur))
        return parts
    }

    /// Stable sort by length, longest first (alternation takes the first that matches).
    private static func longestFirst(_ keys: [String]) -> [String] {
        keys.enumerated().sorted {
            let a = $0.element.unicodeScalars.count, b = $1.element.unicodeScalars.count
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
    }

    /// str.isupper(): at least one cased letter, and none of them lowercase or titlecase.
    private static func isUpper(_ s: String) -> Bool {
        var cased = false
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .uppercaseLetter: cased = true
            case .lowercaseLetter, .titlecaseLetter: return false
            default: break
            }
        }
        return cased
    }

    /// pattern.sub(function, text) for the first capture-free replacement.
    private static func sub(_ re: NSRegularExpression, in text: String, _ replace: (String) -> String) -> String {
        let ns = text as NSString
        var out = "", pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            out += replace(ns.substring(with: m.range))
            pos = m.range.location + m.range.length
        }
        return out + ns.substring(from: pos)
    }
}

/// Replaces as many recognized words as a rare term has (up to 3) when they are close to it: by
/// spelling (Damerau-Levenshtein similarity >= 0.75 over the letters) or by sound (same Kölner
/// Phonetik code and similarity >= 0.6). Spans shorter than 5 letters, spans made only of common
/// words and single words that are real words stay: a real word beats a guess.
private final class FuzzyTerms {
    private var text: [String: String] = [:]  // letters-only key -> term
    private var keys: [Int: [[Unicode.Scalar]]] = [:]  // word count -> keys
    private var keyStrings: [Int: [String]] = [:]
    private var sounds: [String: Set<String>] = [:]
    private let freq: WordFrequency

    init(terms list: [VocabTerm], frequency: WordFrequency) {
        freq = frequency
        for t in list {
            let key = String(String.UnicodeScalarView(t.text.lowercased().unicodeScalars.filter(Self.isWordChar)))
            let words = VocabNormalizer.sepSplit(t.text.pyStrip)
            if key.unicodeScalars.count >= 5, words.count <= 3, !(words.count == 1 && freq.common(words[0])), text[key] == nil {
                text[key] = t.text
                keys[words.count, default: []].append(Array(key.unicodeScalars))
                keyStrings[words.count, default: []].append(key)
            }
        }
        for key in text.keys { sounds[Self.cologne(key), default: []].insert(key) }
    }

    /// Python's [^\W\d_]: letters (and numeric symbols), no digits, no underscore, no marks.
    static func isWordChar(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    func fix(_ input: String) -> String {
        if keys.isEmpty { return input }
        let s = Array(input.unicodeScalars)
        var words: [Range<Int>] = []
        var i = 0
        while i < s.count {
            if Self.isWordChar(s[i]) {
                var j = i
                while j < s.count, Self.isWordChar(s[j]) { j += 1 }
                words.append(i..<j)
                i = j
            } else { i += 1 }
        }
        var out = String.UnicodeScalarView(), pos = 0
        i = 0
        search: while i < words.count {
            for n in [3, 2, 1] {
                guard i + n <= words.count else { continue }
                let span = Array(words[i..<(i + n)])
                // only words joined by spaces or hyphens, not across punctuation
                var joined = true
                for (a, b) in zip(span, span.dropFirst()) {
                    let gap = s[a.upperBound..<b.lowerBound]
                    if gap.isEmpty || !gap.allSatisfy(VocabNormalizer.isSep) { joined = false }
                }
                if !joined { continue }
                let spanWords = span.map { String(String.UnicodeScalarView(s[$0])) }
                let key = spanWords.map { $0.lowercased() }.joined()
                let scalars = Array(key.unicodeScalars)
                if keys[n] == nil || scalars.count < 5 || text[key] != nil
                    || spanWords.allSatisfy({ freq.common($0, zipf: n > 1 ? 4.0 : 3.0) }) { continue }
                // extractOne: the best score above 0.6 (rapidfuzz drops exactly 0.6, e.g. 2 edits in 5 letters), the first of equals.
                var best: (index: Int, score: Double)?
                for (k, cand) in keys[n]!.enumerated() {
                    let score = Self.similarity(scalars, cand)
                    if score > 0.6, score > (best?.score ?? -1) { best = (k, score) }
                }
                guard let b = best else { continue }
                let match = keyStrings[n]![b.index]
                if b.score < 0.75, !(sounds[Self.cologne(key)]?.contains(match) ?? false) { continue }
                out.append(contentsOf: s[pos..<span[0].lowerBound])
                out.append(contentsOf: text[match]!.unicodeScalars)
                pos = span[n - 1].upperBound
                i += n
                continue search
            }
            i += 1
        }
        out.append(contentsOf: s[pos...])
        return String(out)
    }

    // MARK: Similarity

    /// rapidfuzz's DamerauLevenshtein.normalized_similarity: 1 - distance / longer length.
    static func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        let maxLen = max(a.count, b.count)
        if maxLen == 0 { return 1 }
        return 1 - Double(damerauLevenshtein(a, b)) / Double(maxLen)
    }

    /// The unrestricted Damerau-Levenshtein distance (a substring can be edited after a transposition).
    static func damerauLevenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let maxDist = a.count + b.count
        var da: [Unicode.Scalar: Int] = [:]
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 2), count: a.count + 2)
        d[0][0] = maxDist
        for i in 0...a.count { d[i + 1][0] = maxDist; d[i + 1][1] = i }
        for j in 0...b.count { d[0][j + 1] = maxDist; d[1][j + 1] = j }
        for i in 1...a.count {
            var db = 0
            for j in 1...b.count {
                let i1 = da[b[j - 1]] ?? 0, j1 = db
                var cost = 1
                if a[i - 1] == b[j - 1] { cost = 0; db = j }
                d[i + 1][j + 1] = min(d[i][j] + cost, d[i + 1][j] + 1, d[i][j + 1] + 1,
                                      d[i1][j1] + (i - i1 - 1) + 1 + (j - j1 - 1))
            }
            da[a[i - 1]] = i
        }
        return d[a.count + 1][b.count + 1]
    }

    /// Kölner Phonetik: German sound code, "Meyer" and "Maier" are both "67".
    static func cologne(_ word: String) -> String {
        let map: [Unicode.Scalar: Unicode.Scalar] = ["ä": "a", "ö": "o", "ü": "u", "ß": "s"]
        let w: [Character] = word.lowercased().unicodeScalars.map { map[$0] ?? $0 }
            .filter { $0.value >= 97 && $0.value <= 122 }.map { Character($0) }
        var codes: [Character] = []
        for (i, c) in w.enumerated() {
            let prev: Character? = i > 0 ? w[i - 1] : nil
            let next: Character? = i + 1 < w.count ? w[i + 1] : nil
            func nextIn(_ s: String) -> Bool { next.map { s.contains($0) } ?? false }
            let code: String
            if "aeijouy".contains(c) { code = "0" }
            else if c == "h" { continue }
            else if c == "b" || (c == "p" && next != "h") { code = "1" }
            else if c == "d" || c == "t" { code = nextIn("csz") ? "8" : "2" }
            else if "fvw".contains(c) || c == "p" { code = "3" }
            else if "gkq".contains(c) { code = "4" }
            else if c == "c" {
                if i == 0 { code = nextIn("ahkloqrux") ? "4" : "8" }
                else { code = nextIn("ahkoqux") && prev != "s" && prev != "z" ? "4" : "8" }
            }
            else if c == "x" { code = prev == "c" || prev == "k" || prev == "q" ? "8" : "48" }
            else if c == "l" { code = "5" }
            else if c == "m" || c == "n" { code = "6" }
            else if c == "r" { code = "7" }
            else { code = "8" }
            codes.append(contentsOf: code)
        }
        var out: [Character] = []
        for c in codes where out.last != c { out.append(c) }
        guard let first = out.first else { return "" }
        return String(first) + String(out.dropFirst().filter { $0 != "0" })
    }
}

// MARK: Self-test

extension VocabNormalizer {
    /// The asserts from vocab.py's __main__, with the same strings, plus cologne and the parser's edge cases.
    static func selfTest() -> Bool {
        var ok = true
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got != want { ok = false; print("FAIL normalizer: \(what): got \(got), want \(want)") }
        }
        if WordFrequencyTable.shared.isEmpty { print("FAIL normalizer: wordfreq.tsv missing (scripts/make-wordfreq.py)"); return false }

        let start = VocabularyParser.start, end = VocabularyParser.end
        var sample = VocabularyFile.template.replacingOccurrences(of: "## Terms\n", with: "## Terms\n- ACME\n- pull request (heard as: pool request, pul request)\n")
        sample = sample.replacingOccurrences(of: "## Ignore\n", with: "## Ignore\n- Helper\n")
        sample += "\n\(start) x -->\n## From vault: Notes\n### People\n- Jana Weber\n- ACME\n### Terms\n- Helper\n\(end)\n"
        var v = VocabularyParser.parse(sample)
        check(v.terms.map { "\($0.text)/\($0.isVault ? "vault" : "manual")" }, ["ACME/manual", "pull request/manual", "Jana Weber/vault"], "parse terms")
        check(v.ignored, ["Helper"], "ignore")
        var n = VocabNormalizer(v)
        check(n.normalize("the pool request and a Pool Request."), "the pull request and a pull request.", "alias")
        check(n.normalize("a whirlpool requester"), "a whirlpool requester", "alias boundary")

        n = VocabNormalizer(markdown: "## Terms\n- ToP\n- IonianFlow\n- Data Garage\n- Netvora\n- ETL\n- ACME\n")
        for (raw, want) in [
            ("the top shelf is full", "the top shelf is full"),
            ("an open flow of ideas, in Ionianflow", "an open flow of ideas, in IonianFlow"),
            ("im data garage und im Datagarage", "im Data Garage und im Data Garage"),
            ("Net vora baut für die acme", "Netvora baut für die ACME"),
            ("die E T L Planung", "die ETL Planung"),
        ] { check(n.normalize(raw), want, raw) }

        // Fuzzy: by spelling and by sound, and the guards.
        n = VocabNormalizer(markdown: "## Terms\n- Netvora\n- Jana Weber\n- Northwind Logistics\n- Gamma\n")
        for (raw, want) in [
            ("bei Netfora", "bei Netvora"),
            ("Jana Waber schrieb", "Jana Weber schrieb"),
            ("Northwind Logistic", "Northwind Logistics"),
            ("das Gamma Modell", "das Gamma Modell"),
            ("ein netvoraa", "ein Netvora"),
        ] { check(n.normalize(raw), want, raw) }

        check(FuzzyTerms.cologne("Meyer"), "67", "cologne Meyer")
        check(FuzzyTerms.cologne("Maier"), "67", "cologne Maier")
        check(FuzzyTerms.cologne("Müller-Lüdenscheidt"), FuzzyTerms.cologne("Mueller Ludenscheidt"), "cologne umlauts")
        check(FuzzyTerms.damerauLevenshtein(Array("ca".unicodeScalars), Array("abc".unicodeScalars)), 2, "unrestricted DL")

        // Parser edge cases shared with vocab.parse: CRLF, tab bullets, the first non-empty Domain line.
        v = VocabularyParser.parse("Domain:\r\nDomain: Logistics\r\n## Terms\r\n-\tACME\r\n* Jana (heard as: Jaana, Yana)\r\n---\r\n")
        check(v.domain, "Logistics", "domain")
        check(v.terms.map(\.text), ["ACME", "Jana"], "crlf and tab bullets")
        check(v.terms.last?.aliases ?? [], ["Jaana", "Yana"], "aliases")

        // Vault block: rewritten in place, domain filled once, old markers upgraded.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ionian-flow-vocab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Vocabulary.md")
        do {
            try VocabularyFile.writeVaultBlock(to: url, groups: [("People", ["Jana Weber"]), ("Acronyms", ["ToP"])], heading: "From vault: Notes", domain: "logistics IT")
            try VocabularyFile.writeVaultBlock(to: url, groups: [("People", ["Max Muster"])], heading: "From vault: Notes", domain: "something else")
            let w = VocabularyParser.parse(try String(contentsOf: url, encoding: .utf8))
            check(w.domain, "logistics IT", "vault domain")
            check(w.terms.map(\.text), ["Max Muster"], "vault block")
            try "Domain:\n## Terms\n- ACME\n<!-- openflow:vault:start x -->\n## old\n### People\n- Old\n<!-- openflow:vault:end -->\n".write(to: url, atomically: true, encoding: .utf8)
            try VocabularyFile.writeVaultBlock(to: url, groups: [("People", ["New"])], heading: "h")
            let text = try String(contentsOf: url, encoding: .utf8)
            check(text.contains("openflow"), false, "old marker upgraded")
            check(VocabularyParser.parse(text).terms.map(\.text), ["ACME", "New"], "old block replaced")
        } catch { ok = false; print("FAIL normalizer: vault block: \(error)") }

        print(ok ? "normalizer ok" : "normalizer FAILED")
        return ok
    }

    /// Dev hook for scripts/vocab_parity.py: `--wordfreq-zipf words.txt` prints "de en" Zipf values per line.
    static func zipfFile(_ path: String) -> Bool {
        guard let words = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let f = WordFrequencyTable.shared
        for w in words.components(separatedBy: "\n") {
            let lw = w.lowercased()
            print(String(format: "%.2f %.2f", f.zipf(lw, lang: .de), f.zipf(lw, lang: .en)))
        }
        return true
    }

    /// Dev hook for scripts/vocab_parity.py: `--vocab-normalize vocab.md lines.txt` prints each line normalized.
    static func normalizeFile(vocabulary: String, input: String) -> Bool {
        guard let md = try? String(contentsOfFile: vocabulary, encoding: .utf8),
              let lines = try? String(contentsOfFile: input, encoding: .utf8) else { return false }
        let n = VocabNormalizer(markdown: md)
        for line in lines.components(separatedBy: "\n") { print(n.normalize(line)) }
        return true
    }
}
