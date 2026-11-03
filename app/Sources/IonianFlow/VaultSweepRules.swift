import Foundation

// Unit F: the rule pipeline of asr/sweep.py (candidates, keep_candidate, plausible, fix_category, extract).
// Same regexes, same order of decisions; comments name the Python function each piece comes from.

struct SweepTerm: Codable, Equatable {
    var term: String
    var category: String
    var count: Int
    var alias: Bool
    var lower: Bool
}

enum SweepRules {
    static let categories = ["People", "Organizations", "Projects", "Products", "Acronyms", "Terms"]
    static let skipDirs: Set<String> = ["_templates", "templates", "_archive", "attachments", "node_modules"]
    static let words: WordFrequencyTable = .shared

    static let frontmatter = SweepRe(#"\A---\n(.*?)\n---\n"#, .dotMatchesLineSeparators)
    static let fence = SweepRe(#"```.*?```|~~~.*?~~~"#, .dotMatchesLineSeparators)
    static let inlineCode = SweepRe(#"`[^`\n]*`"#)
    static let url = SweepRe(#"https?://\S+|www\.\S+"#)
    static let mdLink = SweepRe(#"\[([^\]]*)\]\([^)]*\)"#)
    static let wikilink = SweepRe(#"!?\[\[([^\]|#]*)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]"#)
    static let html = SweepRe(#"<[^>]+>"#)
    static let heading = SweepRe(#"^#{1,6}\s+(.*)$"#, .anchorsMatchLines)
    static let shaped = SweepRe(#"(?<![\w/])(?=[\w.+&/-]*[A-ZÄÖÜ][\w.+&/-]*[A-ZÄÖÜ0-9])[A-ZÄÖÜa-z][\w+&/-]*[\w+](?![\w/])"#)
    static let cap = #"[A-ZÄÖÜ][a-zäöüß]+(?:-[A-ZÄÖÜ][a-zäöüß]+)?"#
    static let connect = #"(?:of|for|the|de|der|die|das|für|von|van|du)"#
    static let phrase = SweepRe(#"(?<!\w)("# + cap + #"(?:\s+(?:"# + connect + #"\s+)?"# + cap + #"){1,3})(?!\w)"#)
    static let word = SweepRe(#"(?<![\w.])"# + cap + #"(?!\w)"#)
    static let sentenceStart = SweepRe(#"(?:^|[.!?:;]\s+|^\s*[-*>]\s+|\*\*)$"#)
    static let dateish = SweepRe(#"^\d|^(?:Q[1-4]|KW|CW)\d"#, .caseInsensitive)
    static let ticket = SweepRe(#"^[A-Z]+-\d+$"#)
    static let code = SweepRe(#"^[A-Z]\d{1,2}$"#)
    static let hex = SweepRe(#"^[0-9A-F]{6}$"#)
    static let calendar: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun", "jan", "feb", "mar", "apr", "jun", "jul", "aug",
                                        "sep", "sept", "oct", "nov", "dec", "mo", "di", "mi", "do", "fr", "sa", "so", "okt", "dez", "mär"]
    static let sep = SweepRe(#"[\s-]+"#)
    static let allCapsSlash = SweepRe(#"^[A-Z0-9/]+$"#)
    static let logSuffix = SweepRe(#"\s+[Ll]og$"#)
    static let fmKey = SweepRe(#"^([\w-]+):\s*(.*)$"#, .anchorsMatchLines)
    static let fmItem = SweepRe(#"^\s+-\s+(.*)$"#, .anchorsMatchLines)
    static let punct = " .,:;!?()[]*_\"'“”„"

    static let filename = SweepRe(#"_|\s[-–]\s|[:,;]|\.(md|pdf|pptx?|docx?|xlsx?|png|jpe?g|csv)$|\b[A-Z]+-\d+\b"#, .caseInsensitive)
    static let transcript = SweepRe(#"\A# Transcript · "#)
    static let honorific = SweepRe(#"^(?:Frau|Herr|Dr\.?|Prof\.?|Mr\.?|Mrs\.?|Ms\.?)\s+"#)
    static let pronouns: Set<String> = ["you", "them", "me", "we", "us", "they", "he", "she", "him", "her", "ich", "du", "wir", "ihr", "sie",
                                        "er", "mich", "dich", "mir", "dir", "uns", "euch", "ihn", "ihm", "ihnen"]
    static let role = SweepRe(#"(?:analyst|owner|manager|lead|engineer|developer|architect|designer|scientist|consultant|"#
        + #"director|officer|supervisor|speaker|organizer|examiner|coach|admin|user|customer|member|"#
        + #"leiter|berater|entwickler|betreuer|prüfer|gutachter|sprecher|kunde|nutzer|kollege|kollegin)s?$"#, .caseInsensitive)
    static let nameWord = SweepRe(#"^(?:[A-ZÄÖÜÉ][a-zäöüßéèáíóúñçã'’]+(?:-[A-ZÄÖÜ][a-zäöüßéèáíóúñçã'’]+)?|van|von|de|da|del|di|du|der|den)$"#)
    static let numbered = SweepRe(#"^(\S+)\s+(?:\d+(?:\.\d+)*|[IVX]+|v\d+)$"#)
    static let monthDay = SweepRe(#"^(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d"#, .caseInsensitive)
    static let slot = SweepRe(#"^\s*[-*]?\s*(person|organization|project|product|acronym|term)s?\s*:\s*(.+?)\s*$"#,
                              [.caseInsensitive, .anchorsMatchLines])
    static let category: [String: String] = ["person": "People", "organization": "Organizations", "project": "Projects",
                                             "product": "Products", "acronym": "Acronyms", "term": "Terms"]

    // MARK: word frequency (known_word, zipf, vocab.common)

    static func zipf(_ w: String) -> Double {
        let l = w.lowercased()
        return max(words.zipf(l, lang: .de), words.zipf(l, lang: .en))
    }
    static func knownWord(_ w: String) -> Bool { zipf(w) >= 3.0 }
    static func common(_ w: String) -> Bool { zipf(w) >= 4.0 }

    // MARK: frontmatter and candidates

    /// (aliases, other short string values) from simple YAML frontmatter.
    static func frontmatterValues(_ fm: String) -> (aliases: [String], values: [String]) {
        var aliases: [String] = [], values: [String] = []
        var key: String?
        for line in VocabularyParser.splitLines(fm) {
            var items: [String]
            if let m = fmKey.first(line) {
                key = m.group(1)!.lowercased()
                let rest = m.group(2)!.pyStrip
                items = rest.hasPrefix("[") ? rest.pyStrip(chars: "[]").components(separatedBy: ",").map { $0.pyStrip(chars: " '\"") }
                    : [rest.pyStrip(chars: "'\"")]
            } else if let m = fmItem.first(line) {
                items = [m.group(1)!.pyStrip(chars: " '\"")]
            } else { continue }
            for item in items where !item.isEmpty {
                if item.contains("[[") { continue }
                if key == "aliases" || key == "alias" { aliases.append(item) } else { values.append(item) }
            }
        }
        return (aliases, values)
    }

    struct Candidate { var count = 0; var kind: String }

    /// term -> (count, kind) for one note, in the order the terms were first found.
    static func candidates(_ text: String, stem: String) -> OMap<Candidate> {
        var found = OMap<Candidate>()
        func add(_ raw: String, _ kind: String) {
            var term = raw.pyStrip(chars: punct)
            term = logSuffix.sub(term, "")
            if term.contains("/"), !allCapsSlash.test(term) {
                for part in term.components(separatedBy: "/") { add(part, kind) }
                return
            }
            if term.cpCount < 2 || term.cpCount > 40 || dateish.test(term) || term.contains("_") || term.filter({ $0 == " " }).count > 4 { return }
            found.update(term, default: Candidate(kind: kind)) { $0.count += 1 }
        }
        var body = text
        if let m = frontmatter.matchAtStart(text) {
            let (aliases, values) = frontmatterValues(m.group(1)!)
            for a in aliases { add(a, "alias") }
            for v in values {
                for s in shaped.all(v).map(\.whole) + phrase.all(v).map { $0.group(1)! } { add(s, "shaped") }
            }
            body = (text as NSString).substring(from: m.end)
        }
        for m in wikilink.all(body) {
            let target = m.group(1) ?? "", alias = m.group(2) ?? ""
            if !alias.isEmpty { add(alias, "alias") }
            else if !target.isEmpty, target != target.lowercased() { add(target.components(separatedBy: "/").last!, "link") }
        }
        if stem != stem.lowercased(), !dateish.test(stem) { add(stem, "title") }
        body = html.sub(url.sub(inlineCode.sub(fence.sub(body, " "), " "), " "), " ")
        body = mdLink.sub(body) { $0.group(1) ?? "" }
        body = wikilink.sub(body) { m in
            if let a = m.group(2), !a.isEmpty { return a }
            return m.group(1) ?? ""
        }
        for line in VocabularyParser.splitLines(body) {
            if line.pyStrip.isEmpty { continue }
            if let h = heading.matchAtStart(line), line.hasPrefix("# ") {
                let title = h.group(1)!.components(separatedBy: CharacterSet(charactersIn: ":(–—|"))[0]
                if !title.pyStrip.isEmpty { add(title, "title") }
            }
            for s in shaped.all(line) { add(s.whole, "shaped") }
            for s in phrase.all(line) { add(s.group(1)!, "phrase") }
            for m in word.all(line) {
                // A capitalized word mid-sentence, rare in both languages: names, products.
                if !sentenceStart.test((line as NSString).substring(to: m.start)) { add(m.whole, "word") }
            }
        }
        return found
    }

    static func keepCandidate(_ term: String, kind: String) -> Bool {
        if ticket.test(term) || hex.test(term) || calendar.contains(term.lowercased()) { return false }
        if term.contains("-"), term.components(separatedBy: "-").contains(where: { common($0) && $0.pyIsLower }) { return false }
        if ["alias", "title", "link"].contains(kind) { return true }
        let ws = sep.split(term)
        if ws.count == 1 {
            return !common(term) || (!term.pyIsUpper && term.unicodeScalars.filter { String($0).pyIsUpper }.count >= 2)
        }
        return !ws.allSatisfy { common($0) }
    }

    static func letters(_ term: String) -> [Unicode.Scalar] { term.unicodeScalars.filter { String($0).pyIsAlpha } }

    static func isAcronymShaped(_ term: String) -> Bool {
        let l = letters(term)
        return !term.contains(" ") && !l.isEmpty && l.filter { String($0).pyIsUpper }.count * 2 > l.count
    }

    /// Without the LLM: shape only.
    static func guessCategory(_ term: String) -> String { isAcronymShaped(term) ? "Acronyms" : "Terms" }

    static func fixCategory(_ term: String, _ category: String) -> String {
        let acronym = isAcronymShaped(term)
        if category == "People", !term.pySplit.allSatisfy({ nameWord.test($0) }) { return acronym ? "Acronyms" : "Terms" }
        if acronym && category != "People" { return "Acronyms" }
        if category == "Acronyms" { return "Terms" }
        return category
    }

    static func wellFormed(_ term: String) -> Bool {
        sep.split(term).allSatisfy { w in
            let f = w.cpPrefix(1)
            return f.pyIsUpper || f.pyIsDigit
        }
    }

    /// A name worth knowing, not a status, a code or a phrase. `lowercaseToo`: the note also writes it
    /// in lowercase (a role: "our product owner"; a name never is).
    static func plausible(_ term: String, _ category: String, lowercaseToo: Bool) -> Bool {
        if !(2...40).contains(term.cpCount) || term.filter({ $0 == " " }).count > 3 || filename.test(term) || dateish.test(term) { return false }
        if monthDay.test(term) { return false }
        if ticket.test(term) || code.test(term) || hex.test(term) || term.pyIsDigit || pronouns.contains(term.lowercased()) { return false }
        if calendar.contains(term.lowercased()) && category != "People" { return false }
        if term == term.lowercased() && !term.contains(" ") { return false }
        let ws = sep.split(term)
        if role.test(term) && ws.allSatisfy({ knownWord($0) }) { return false }
        if category == "People" { return !lowercaseToo }
        if term.pyIsUpper && ws.allSatisfy({ ($0.cpCount >= 4 && knownWord($0)) || zipf($0) >= 5 }) { return false }
        if let m = numbered.matchAtStart(term), knownWord(m.group(1)!) { return false }
        if ws.count > 1 && ws.allSatisfy({ $0 == $0.lowercased() }) { return false }
        if !term.contains(" "), term.cpPrefix(1).pyIsUpper, term.cpDropFirst(1).pyIsLower, knownWord(term) { return false }
        if term.pyIsUpper && !term.contains(" ") && term.cpCount <= 5 { return true }
        if ws.count > 1 && wellFormed(term) {
            return !ws.allSatisfy { common($0) } || ws.map { zipf($0) }.max()! < 5.5
        }
        return keepCandidate(term, kind: "llm")
    }

    // MARK: reading a note

    /// (note body as prose, the note's own aliases): no frontmatter, code or URLs; links become their text.
    static func plain(_ text: String) -> (body: String, aliases: [String]) {
        var text = text, aliases: [String] = []
        if let m = frontmatter.matchAtStart(text) {
            aliases = frontmatterValues(m.group(1)!).aliases
            text = (text as NSString).substring(from: m.end)
        }
        aliases += wikilink.all(text).compactMap { $0.group(2) }.filter { !$0.isEmpty }
        text = html.sub(url.sub(inlineCode.sub(fence.sub(text, " "), " "), " "), " ")
        text = mdLink.sub(text) { $0.group(1) ?? "" }
        text = wikilink.sub(text) { m in
            if let a = m.group(2), !a.isEmpty { return a }
            return (m.group(1) ?? "").components(separatedBy: "/").last!
        }
        return (text, aliases)
    }

    /// Paragraph-aligned pieces small enough for a small model to read closely.
    static func chunks(_ text: String, size: Int = 2000) -> [String] {
        var out: [String] = [], cur = ""
        var curLen = 0
        for para in text.components(separatedBy: "\n\n") {
            let n = para.cpCount
            if !cur.isEmpty && curLen + n > size { out.append(cur); cur = ""; curLen = 0 }
            cur += para + "\n\n"
            curLen += n + 2
        }
        if !cur.pyStrip.isEmpty { out.append(cur) }
        return out
    }

    private static func wholeWord(_ term: String) -> String { #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: term) + #"(?!\w)"# }

    /// The note's most common spelling, preferring one with capitals: "lumai" -> "LumAI".
    static func spelling(_ term: String, _ text: String) -> String {
        let forms = SweepRe(wholeWord(term), .caseInsensitive).all(text).map(\.whole)
        if forms.isEmpty { return term }
        let cased = forms.filter { $0 != $0.lowercased() }
        let pool = cased.isEmpty ? forms : cased
        var counter = OCounter()
        for f in pool { counter.add(f) }
        return counter.top!  // Python breaks ties by set order (random); here the first seen wins
    }

    static func extractRules(_ text: String, stem: String) -> [SweepTerm] {
        var out: [SweepTerm] = []
        for (t, c) in candidates(text, stem: stem).pairs where keepCandidate(t, kind: c.kind) {
            out.append(SweepTerm(term: t, category: guessCategory(t), count: c.count, alias: ["alias", "title", "link"].contains(c.kind), lower: false))
        }
        return out
    }

    /// Terms the LLM found in one note, checked against the note word for word. The filters run in
    /// rank(), so changing them needs no new LLM pass.
    static func extract(_ text: String, ask: (String) async throws -> String) async throws -> [SweepTerm] {
        let (body, aliases) = plain(text)
        let bodyLower = body.lowercased()
        var found = OMap<SweepTerm>()
        func add(_ raw: String, _ category: String, alias: Bool = false) {
            let parts = raw.contains("/") && !allCapsSlash.test(raw) ? raw.components(separatedBy: "/") : [raw]
            for part in parts {
                var term = part.pyStrip(chars: punct)
                term = honorific.sub(SweepRe(#"\s+[Ll]og$|['’]s$"#).sub(term, ""), "")
                if term.isEmpty || (!bodyLower.pyContains(term.lowercased()) && !alias) { continue }
                term = spelling(term, body)
                let n = max(1, SweepRe(wholeWord(term), .caseInsensitive).all(body).count)
                if var e = found[term] { e.count = n; found[term] = e; continue }
                let lower = term != term.lowercased() && SweepRe(wholeWord(term.lowercased())).test(body)
                found[term] = SweepTerm(term: term, category: fixCategory(term, category), count: n, alias: alias, lower: lower)
            }
        }
        for chunk in chunks(body) {
            let answer = try await ask("Note:\n" + chunk.pyStrip + "\nAnswer:")
            let chunkLower = chunk.lowercased()
            for m in slot.all(answer) {
                let value = m.group(2)!
                if chunkLower.pyContains(value.pyStrip.lowercased()) { add(value, category[m.group(1)!.lowercased()]!) }
            }
        }
        for a in aliases where found[a] == nil { add(a, guessCategory(a), alias: true) }  // the user named it
        return found.values
    }
}
