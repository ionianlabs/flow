import Foundation

enum InstinctModelError: Error { case unparsable(String) }

/// Instinct's model step on Gemma (item 10): one prompt per chunk of sources for extraction, one per duplicate judgement.
/// Built on any `VaultLLM`, so the sweep's `SweepControl` pauses it per token and tests use a fake.
struct GemmaInstinctModel: InstinctModel {
    static let extractMaxTokens = 800
    static let judgeMaxTokens = 60
    static let judgeLineLimit = 20

    let llm: VaultLLM

    init(llm: VaultLLM) { self.llm = llm }

    init(control: SweepControl?, hub: ModelHub = .shared) { llm = GemmaVaultLLM(hub: hub, control: control) }

    func extract(_ sources: [InstinctSource], projects: [InstinctProjectHint]) async throws -> [InstinctItem] {
        let answer = try await llm.chat(Self.extractMessages(sources, projects: projects), maxTokens: Self.extractMaxTokens)
        guard var items = InstinctParsing.items(answer) else { throw InstinctModelError.unparsable(answer) }
        for i in items.indices { items[i].sourceID = Self.resolve(items[i], in: sources) }
        return items
    }

    /// The prompt numbers sources S1, S2, ... (short ids are copied reliably); this maps the answer back to the real
    /// id. A wrong number falls back to the source that contains the quote; with none, the id stays as the model wrote it.
    static func resolve(_ item: InstinctItem, in sources: [InstinctSource]) -> String {
        let said = item.sourceID.trimmingCharacters(in: CharacterSet(charactersIn: "[]() \"`"))
        if let n = Int(said.drop(while: { !$0.isNumber })), said.first == "S" || said.first == "s", sources.indices.contains(n - 1),
           InstinctParsing.isVerbatim(item.quote, in: sources[n - 1].text) { return sources[n - 1].id }
        if let hit = sources.first(where: { InstinctParsing.isVerbatim(item.quote, in: $0.text) }) { return hit.id }
        if let own = sources.first(where: { $0.id == said }) { return own.id }
        return said
    }

    func judge(_ item: InstinctItem, against lines: [String]) async throws -> InstinctVerdict {
        let lines = Array(lines.prefix(Self.judgeLineLimit))
        if lines.isEmpty { return .new }
        let answer = try await llm.chat(Self.judgeMessages(item, lines), maxTokens: Self.judgeMaxTokens)
        guard let v = InstinctParsing.verdict(answer) else { throw InstinctModelError.unparsable(answer) }
        if case .conflicts(let said) = v {  // the prompt shows lines without list markers; hand back the brain's own line
            let key = Self.plain(said)
            if let own = lines.first(where: { $0 == said }) ?? lines.first(where: { Self.plain($0) == key }) { return .conflicts(own) }
        }
        return v
    }

    /// A brain line as the model sees it: no list bullet or checkbox.
    static func plain(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "- [~] ", "- [-] ", "- [=] ", "- ", "* "] where s.hasPrefix(marker) {
            s = String(s.dropFirst(marker.count)); break
        }
        return s
    }

    // MARK: prompts

    static let extractSystem = """
    You read short pieces of the user's own speech (meeting transcripts and dictations) and pick out the few things worth keeping in their notes. Precision matters far more than recall: a wrong item costs the user attention, a missed one costs little. When in doubt, skip. An empty list is normal and expected.

    Input: numbered sources. Each has an id, a date with weekday, who spoke ("You" is the user, "Them" is someone else) or the app it was dictated in, and the text. Then the project list as "slug: description; focus".

    Find only three kinds of item:
    - todo: a concrete action the user has to do. This includes requests other people make of the user ("Can you send me the budget by Friday?"). Set "due" (YYYY-MM-DD, worked out from the source's own date and weekday) only when a date or weekday is said. Set "owner" only when a person is named as the one who does it.
    - decision: a choice that was settled in the conversation, said as settled ("we will", "we go with", "decided", "final"), not a proposal and not an opinion.
    - fact: a lasting, specific piece of knowledge about a project that contains a concrete date, number, name or status change ("the audit is on 3 March", "the old service is now called X", "the sync handles 40,000 records"). A statement without such a concrete detail is not a fact.

    Skip all of these: small talk, questions without a commitment, maybes and hypotheticals ("we could", "maybe someday"), opinions, impressions and assessments ("X is stable", "X is further along than people think", "X is hard to get right", "X looks better in the demo"), things already done, generic statements, and remarks about the conversation itself ("we could talk about X for hours", "let me think"). Examples that give no item: "maybe we should try a darker theme at some point", "the printer is kind of annoying", "did you see the game?", "I will have lunch now", "the new layout is much nicer than before".
    A mechanical test before you list anything: the source must contain a cue. For a todo: a request or obligation ("can you", "please", "I need to", "I will", "don't forget", "by Friday", "remind me"). For a decision: a settlement ("decided", "settled", "final", "we go with", "we will use", "we are not renewing"). For a fact: a concrete date, number, amount or new name ("on 3 March", "40,000 records", "is now called X", "opens on the 18th"). A source with none of these cues is skipped, however interesting it sounds.
    If you would give an item a confidence below 0.7, leave it out instead of listing it. Most sources give no item at all, and a stretch of pure discussion gives none: answer {"items":[]}. Never invent an item to have something to list.

    For every item give:
    - "category": todo, decision or fact.
    - "text": one short sentence in English. Imperative for a todo ("Send the budget"), a plain statement otherwise.
    - "owner": a person's name or null.
    - "due": YYYY-MM-DD or null.
    - "quote": the exact words copied from the source, character for character, at most 25 words, containing the item. Copy a short stretch; never paraphrase, never translate, never fix grammar, never join words from different places.
    - "source": the number of the source the quote comes from, such as "S3".
    - "project": a listed slug only when the item's own words concern that project's description or focus; a remark about teams, tools, a general process or the conversation is "none". Most items are "none".
    - "confidence": 0 to 1, how sure you are that the item is real, lasting and worth keeping.

    Answer with only this JSON object on a single line, without code fence or explanation: {"items":[{"category":"todo","text":"...","owner":null,"due":null,"quote":"...","source":"...","project":"none","confidence":0.8}]}
    """

    /// Two worked examples as earlier turns (a meeting chunk and a dictation chunk), each skipping most of its sources.
    static let extractShots: [(user: String, answer: String)] = [
        ("""
        Projects:
        garden: Planning of the community garden; Open the beds in May

        Calendar (use it to turn weekdays into dates):
        On Tuesday 2026-03-03: Wednesday 2026-03-04, Thursday 2026-03-05, Friday 2026-03-06, Saturday 2026-03-07, Sunday 2026-03-08, Monday 2026-03-09, Tuesday 2026-03-10

        Sources:
        Source S1 | 2026-03-03 Tuesday 14:00 | Them
        I like how the fence turned out, it looks pretty good. Honestly, the compost corner feels a bit messy to me right now.

        Source S2 | 2026-03-03 Tuesday 14:01 | You
        To be fair, the shed has held up well for a while, so I would not worry. We could maybe add a pond someday.

        Source S3 | 2026-03-03 Tuesday 14:02 | Them
        Can you email the seed list to Ravi by Thursday? He wants to order early.

        Source S4 | 2026-03-03 Tuesday 14:03 | Them
        Last winter the tool store was a headache for me, and these days I barely notice it. How was your weekend?

        Source S5 | 2026-03-03 Tuesday 14:05 | You
        Okay, so we build the raised beds from cedar, that's decided.

        Source S6 | 2026-03-03 Tuesday 14:06 | You
        I keep going back and forth on the watering plan, there are good arguments on both sides. My impression is that the volunteers are further along than people think.

        Source S7 | 2026-03-03 Tuesday 14:07 | Them
        The water meter reading is 1,240 litres per week now.

        Source S8 | 2026-03-03 Tuesday 14:08 | Them
        Yeah, the signup sheet is one of those things where the details matter more than the plan. I think the new map looks better on paper than on the wall.

        Source S9 | 2026-03-03 Tuesday 14:10 | You
        By the way, the office printer lease ends on 30 June, and the tax office closes the filing on 15 May.

        Return the JSON object now.
        """, #"{"items":[{"category":"todo","text":"Email the seed list to Ravi","owner":null,"due":"2026-03-05","quote":"Can you email the seed list to Ravi by Thursday?","source":"S3","project":"garden","confidence":0.9},{"category":"decision","text":"Build the raised beds from cedar","owner":null,"due":null,"quote":"we build the raised beds from cedar, that's decided","source":"S5","project":"garden","confidence":0.9},{"category":"fact","text":"The water meter reads 1,240 litres per week","owner":null,"due":null,"quote":"The water meter reading is 1,240 litres per week now.","source":"S7","project":"garden","confidence":0.8},{"category":"fact","text":"The office printer lease ends on 30 June","owner":null,"due":null,"quote":"the office printer lease ends on 30 June","source":"S9","project":"none","confidence":0.8}]}"#),
        ("""
        Projects:
        garden: Planning of the community garden; Open the beds in May
        bakery: Menu and suppliers for the corner bakery; New menu in April

        Calendar (use it to turn weekdays into dates):
        On Wednesday 2026-03-04: Thursday 2026-03-05, Friday 2026-03-06, Saturday 2026-03-07, Sunday 2026-03-08, Monday 2026-03-09, Tuesday 2026-03-10, Wednesday 2026-03-11

        Sources:
        Source S1 | 2026-03-04 Wednesday 08:10 | dictated in Messages
        Thanks, that sounds great, see you at the market later.

        Source S2 | 2026-03-04 Wednesday 08:12 | dictated in Notes
        Note to self: order the flour from the new supplier before the weekend.

        Source S3 | 2026-03-04 Wednesday 08:15 | dictated in Slack
        I think the old menu was kind of boring but whatever.

        Source S4 | 2026-03-04 Wednesday 08:20 | dictated in Notes
        We decided the sourdough stays on the new menu. Also I need to renew the stall permit.

        Source S5 | 2026-03-04 Wednesday 08:31 | dictated in Mail
        Good morning, I hope you are well, please find the invoice attached.

        Return the JSON object now.
        """, #"{"items":[{"category":"todo","text":"Order the flour from the new supplier","owner":null,"due":null,"quote":"order the flour from the new supplier before the weekend","source":"S2","project":"bakery","confidence":0.9},{"category":"decision","text":"Keep the sourdough on the new menu","owner":null,"due":null,"quote":"We decided the sourdough stays on the new menu.","source":"S4","project":"bakery","confidence":0.9},{"category":"todo","text":"Renew the stall permit","owner":null,"due":null,"quote":"I need to renew the stall permit.","source":"S4","project":"none","confidence":0.85}]}"#),
    ]

    static func extractMessages(_ sources: [InstinctSource], projects: [InstinctProjectHint]) -> [ChatMsg] {
        var m = [ChatMsg(role: "system", content: extractSystem)]
        for shot in extractShots {
            m.append(ChatMsg(role: "user", content: shot.user))
            m.append(ChatMsg(role: "assistant", content: shot.answer))
        }
        m.append(ChatMsg(role: "user", content: extractUser(sources, projects: projects)))
        return m
    }

    static func extractUser(_ sources: [InstinctSource], projects: [InstinctProjectHint]) -> String {
        var out = "Projects:\n"
        if projects.isEmpty { out += "(none)\n" }
        for p in projects { out += "\(p.slug): \(p.description); \(p.focus)\n" }
        out += "\nCalendar (use it to turn weekdays into dates):\n"
        for day in Set(sources.map { cal.startOfDay(for: $0.time) }).sorted() {
            let upcoming = (1...7).compactMap { cal.date(byAdding: .day, value: $0, to: day) }.map { dayFormatter.string(from: $0) }
            out += "On \(dayFormatter.string(from: day)): " + upcoming.joined(separator: ", ") + "\n"
        }
        out += "\nSources:\n"
        for (n, s) in sources.enumerated() {
            let who: String
            switch s.kind {
            case .dictation(let app, _): who = "dictated in \(app)"
            case .transcript: who = s.speaker?.rawValue ?? "unknown speaker"
            }
            out += "Source S\(n + 1) | \(dateFormatter.string(from: s.time)) | \(who)\n\(s.text)\n\n"
        }
        out += "Return the JSON object now."
        return out
    }

    static let judgeSystem = """
    You check a new note against the lines already in the user's notes. Answer with only one JSON object:
    {"verdict":"same"} if one of the lines already says it (same task, decision or fact; other wording, other tense or extra detail in the line is fine),
    {"verdict":"conflicts","line":"<that line copied exactly>"} if one of the lines is about the very same thing but gives a different value (date, number, name, status),
    {"verdict":"new"} if none of the lines covers it. A line about a related topic does not count.
    """

    static func judgeMessages(_ item: InstinctItem, _ lines: [String]) -> [ChatMsg] {
        [ChatMsg(role: "system", content: judgeSystem), ChatMsg(role: "user", content: judgeUser(item, lines))]
    }

    static func judgeUser(_ item: InstinctItem, _ lines: [String]) -> String {
        "Lines already in the notes:\n" + lines.map { "- \(plain($0))" }.joined(separator: "\n")
            + "\n\nNew note: \(item.text)\n\nIs the new note already covered by one of the lines? Answer with the JSON object."
    }

    private static var cal: Calendar { Calendar.current }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE yyyy-MM-dd"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        return f
    }()
}

extension GemmaInstinctModel {
    static let defaultChunkLimit = InstinctRules.chunkLimit
    static let defaultMaxSources = InstinctRules.chunkMaxSources

    static func chunks(_ sources: [InstinctSource], limit: Int = InstinctRules.chunkLimit, maxSources: Int = InstinctRules.chunkMaxSources) -> [[InstinctSource]] {
        InstinctRules.chunks(sources, limit: limit, maxSources: maxSources)
    }
}
