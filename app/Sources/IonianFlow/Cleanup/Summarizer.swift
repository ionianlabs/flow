import Foundation

// Unit F (summaries). Port of the former Python polish.py summary: 12k-character chunks, notes, then JSON; clean_summary
// (tags, keywords present in the transcript, date grounding with WHEN_DE); empty result = nil (no summary).
// Gemma comes from ModelHub.gemma(); generation runs inside ModelHub.serial (see VaultSweepLLM.swift).

final class Summarizer {
    static let chunkSize = 12_000  // characters per part of a long transcript (~3-4k tokens)

    static let summarySystem = #"""
You write the header of a meeting transcript for a personal knowledge base, so the meeting can be
found and understood later without reading it. The speakers are "You" (the note's owner) and "Them"
(everyone on the other side of the call). It was transcribed automatically: expect recognition errors.

Reply with one JSON object and nothing else:
{"description": "...", "tags": [], "keywords": [], "points": [], "decisions": [], "actions": []}
- description: one sentence, at most 25 words: what the meeting was about.
- tags: 2 to 6 topics, lowercase words joined by hyphens. Use tags from "Tags in use" whenever one fits;
  invent one only when none does.
- keywords: up to 10 names, organizations, products, projects and technical terms that were said,
  spelled as in the transcript.
- points: 3 to 6 short bullets with the main content.
- decisions: what was decided; [] if nothing was.
- actions: who does what, as "You: ..." or "Them: ..." or with the person's name; [] if none was agreed.
Write in English. Never invent names, dates, deadlines or numbers that are not in the transcript.
"""#

    static let notesSystem = #"""
Condense this part of a meeting transcript into short notes in English: the main points, what was
decided, who agreed to do what, and the names and technical terms mentioned. Keep the speaker labels
"You" and "Them". Plain bullets, at most 12. Nothing that isn't in the text.
"""#

    /// Days and dates a decision or action may name, German mapped to English: the summary is in English,
    /// the meeting often isn't. ("may"/"Mai" are left out: mostly the verb.) Order matters in the regex.
    static let whenDE: [(String, String)] = [
        ("montag", "monday"), ("dienstag", "tuesday"), ("mittwoch", "wednesday"), ("donnerstag", "thursday"),
        ("freitag", "friday"), ("samstag", "saturday"), ("sonntag", "sunday"), ("januar", "january"),
        ("februar", "february"), ("märz", "march"), ("juni", "june"), ("juli", "july"), ("oktober", "october"),
        ("dezember", "december"), ("morgen", "tomorrow"), ("heute", "today"), ("nächste woche", "next week"),
        ("nächsten woche", "next week"),
    ]
    private static let whenMap = Dictionary(whenDE, uniquingKeysWith: { $1 })
    private static let when = SweepRe(
        #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|"#
            + #"june|july|august|september|october|november|december|tomorrow|today|next week|"#
            + whenDE.map(\.0).joined(separator: "|") + #")\b"#, .caseInsensitive)

    private let llm: VaultLLM?

    init(hub: ModelHub = .shared) { llm = nil; self.hub = hub }
    /// Any chat model (tests).
    init(llm: VaultLLM) { self.llm = llm; hub = .shared }
    private let hub: ModelHub

    /// nil when the model is missing or fails, or answers with nothing usable.
    func summarize(transcript: String, tags: [String]) async -> TranscriptSummary? {
        guard !transcript.pyStrip.isEmpty else { return nil }
        do {
            let model: VaultLLM = llm ?? GemmaVaultLLM(hub: hub)
            let parts = Self.chunks(transcript, Self.chunkSize)
            var material = transcript
            if parts.count != 1 {
                var notes: [String] = []
                for part in parts { notes.append(try await model.ask(Self.notesSystem, part, maxTokens: 400)) }
                material = notes.joined(separator: "\n\n")
            }
            let user = Self.userPrompt(tags: tags, material: material, parts: parts.count)
            let raw = try await model.ask(Self.summarySystem, user, maxTokens: 700)
            return TranscriptSummary(Self.cleanSummary(raw, transcript: transcript))
        } catch {
            NSLog("Ionian Flow: summary failed: %@", "\(error)")
            return nil
        }
    }

    static func userPrompt(tags: [String], material: String, parts: Int) -> String {
        "Tags in use: \(tags.isEmpty ? "(none yet)" : tags.joined(separator: ", "))\n\n"
            + (parts == 1 ? "Transcript:\n\(material)" : "Notes on the meeting, part by part:\n\(material)")
    }

    /// Splits at line breaks into parts of at most `size` characters (a longer line is its own part).
    static func chunks(_ text: String, _ size: Int) -> [String] {
        var parts: [String] = [], cur = "", curLen = 0
        var line = String.UnicodeScalarView(), prevCR = false
        var lines: [String] = []
        for u in text.unicodeScalars {  // splitlines(keepends=True)
            if prevCR {
                prevCR = false
                if u == "\n" { line.append(u); lines.append(String(line)); line = .init(); continue }
                lines.append(String(line)); line = .init()
            }
            line.append(u)
            switch u.value {
            case 0x0D: prevCR = true
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029: lines.append(String(line)); line = .init()
            default: break
            }
        }
        if !line.isEmpty { lines.append(String(line)) }
        for l in lines {
            let n = l.cpCount
            if !cur.isEmpty && curLen + n > size { parts.append(cur); cur = ""; curLen = 0 }
            cur += l
            curLen += n
        }
        parts.append(cur)
        return parts.filter { !$0.pyStrip.isEmpty }
    }

    /// The model's JSON, held to the rules: tags in tag form, keywords that were actually said, no
    /// decision or action naming a day or date nobody mentioned. [:] when there is nothing usable.
    static func cleanSummary(_ raw: String, transcript: String) -> [String: Any] {
        guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"), a <= b,
              let data = PyJSON.parse(String(raw[a...b])), case .object = data else { return [:] }
        let said = transcript.lowercased()
        func whenSet(_ text: String) -> Set<String> {
            Set(when.all(text).map { m in let w = m.whole.lowercased(); return whenMap[w] ?? w })
        }
        let saidWhen = whenSet(transcript)

        func strings(_ key: String, _ limit: Int, _ length: Int = 200) -> [String] {
            var items: [PyJSON] = []
            if let v = data[key], v.truthy {
                if case .array(let a) = v { items = a } else if case .string = v { items = [v] }
            }
            var out: [String] = []
            for raw in items {
                var item: String
                if case .object(let o) = raw {  // {"who": ..., "what": ...} instead of "who: what"
                    let vals = o.map(\.1).filter(\.truthy).map(\.pyStr)
                    item = vals.count > 1 ? "\(vals[0]): \(vals.dropFirst().joined(separator: " "))" : vals.joined(separator: " ")
                } else { item = raw.pyStr }
                item = SweepRe(#"\s+"#).sub(item, " ").pyStrip(chars: " -•*")
                if !item.isEmpty && !out.contains(item) { out.append(item.cpPrefix(length)) }
            }
            return Array(out.prefix(limit))
        }
        func grounded(_ item: String) -> Bool { whenSet(item).isSubset(of: saidWhen) }

        var tags: [String] = []
        for tag in strings("tags", 6) {
            let t = SweepRe(#"[^a-z0-9]+"#).sub(tag.lowercased(), "-").pyStrip(chars: "-")
            if !t.isEmpty && !tags.contains(t) { tags.append(t) }
        }
        let out: [String: Any] = [
            "description": strings("description", 1, 300).joined(separator: " "),
            "tags": tags,
            "keywords": Array(strings("keywords", 15, 60).filter { said.pyContains($0.lowercased()) }.prefix(10)),
            "points": strings("points", 8),
            "decisions": strings("decisions", 8).filter(grounded),
            "actions": strings("actions", 8).filter(grounded),
        ]
        let desc = out["description"] as! String
        return desc.isEmpty && (out["points"] as! [String]).isEmpty ? [:] : out
    }
}

enum SummarizerCLI {
    /// `--enginetest-summary`: summaries on fixture transcripts. Return the process exit code.
    static func cli(_ args: [String]) -> Int32 { SummaryCLI.cli(args) }
}
