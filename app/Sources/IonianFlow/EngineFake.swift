import Foundation

/// A scripted SpeechEngine for model-free tests: it records every call, and the test (or the hooks) emit the
/// events a real engine would. Events are delivered synchronously on the calling thread (main in tests).
final class EngineFake: SpeechEngine {
    var onEvent: (EngineEvent) -> Void = { _ in }
    var isReady = true
    var capabilities: EngineCapabilities

    // Recorded calls.
    private(set) var begun: [SessionOptions] = []
    private(set) var pushed: [SessionID: Int] = [:]  // bytes per session
    private(set) var cuts: [(SessionID, Int)] = []
    private(set) var ended: [SessionID] = []
    private(set) var cancelled: [SessionID] = []
    private(set) var polishCalls: [(id: Int, text: String, before: String)] = []
    private(set) var summaryCalls: [(id: Int, transcript: String)] = []
    private var counters: [Channel: Int] = [:]

    // Scripts: what the fake answers by itself.
    var polishReply: ((String) -> String)?  // nil: never answers
    var summaryReply: TranscriptSummary?  // nil: answers "failed"
    var finalOnEnd: ((SessionID) -> EngineEvent?)?

    init(capabilities: EngineCapabilities = [.polish, .summary]) { self.capabilities = capabilities }

    func emit(_ e: EngineEvent) { onEvent(e) }

    func start() { emit(.ready) }
    func stop() { isReady = false }
    func beginSession(_ o: SessionOptions) -> SessionID {
        begun.append(o)
        counters[o.channel, default: 0] += 1
        return SessionID(channel: o.channel, n: counters[o.channel]!)
    }
    func push(_ s: SessionID, pcm: Data) { pushed[s, default: 0] += pcm.count }
    func cut(_ s: SessionID, at sample: Int) { cuts.append((s, sample)) }
    func end(_ s: SessionID) {
        ended.append(s)
        if let e = finalOnEnd?(s) { emit(e) }
    }
    func cancel(_ s: SessionID) { cancelled.append(s) }
    func reloadVocabulary() {}
    func polish(id: Int, text: String, before: String) {
        polishCalls.append((id, text, before))
        if id != 0, let reply = polishReply { emit(.polished(id: id, text: reply(text))) }
    }
    func summarize(id: Int, transcript: String, tags: [String]) {
        summaryCalls.append((id, transcript))
        emit(.summary(id: id, summaryReply))
    }
}

extension EngineFake {
    /// Transcriber and dictation handling against the fake engine; no models, no audio devices.
    static func selfTest() -> Bool {
        Settings.registerDefaults()
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print(cond ? "PASS" : "FAIL", " fake engine: \(what)")
            ok = ok && cond
        }
        func pump(_ seconds: Double = 5, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ionian-fake-engine-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        /// One two-channel meeting: returns the transcriber, the fake and the segments by speaker.
        func meeting(_ name: String, _ fake: EngineFake) -> Transcriber {
            let t = Transcriber(engine: fake, mic: AudioCapture())
            fake.onEvent = { _ = t.handleMain($0) }
            t.startForFiles(them: true, file: dir.appendingPathComponent(name + ".md"))
            let mic = SessionID(channel: .mic, n: 1), sys = SessionID(channel: .system, n: 1)
            fake.emit(.partial(mic, segment: 0, text: "so the plan is", lang: "en"))
            fake.emit(.partial(sys, segment: 0, text: "yes agreed", lang: "en"))
            fake.emit(.final(mic, segment: 0, text: "um so the plan is to ship on friday", lang: "en", start: 0.2, end: 3.1))
            fake.emit(.final(sys, segment: 0, text: "yes agreed", lang: "en", start: 3.4, end: 4.2))
            return t
        }
        func texts(_ t: Transcriber, _ s: Speaker) -> [String] { t.model.segments.filter { $0.speaker == s }.map(\.text) }

        // 1. Cleanup present: both channels get sessions, finals are polished, a summary arrives.
        do {
            let fake = EngineFake()
            fake.polishReply = { $0 + " [polished]" }
            fake.summaryReply = TranscriptSummary(["description": "A short sync.", "points": ["Ship on Friday."]])
            let t = meeting("with-cleanup", fake)
            check(fake.begun.map(\.channel) == [.mic, .system] && fake.begun.allSatisfy { $0.kind == .transcription },
                  "two transcription sessions on mic and system")
            check(texts(t, .you).first.map { $0.hasSuffix("[polished]") && !$0.lowercased().hasPrefix("um ") } == true,
                  "You segment: filler removed, polished (\(texts(t, .you)))")
            check(texts(t, .them).first?.hasSuffix("[polished]") == true, "Them segment polished")
            check(t.model.segments.allSatisfy { $0.stage == .polished }, "stage polished")
            check(fake.polishCalls.first.map { $0.id == 0 && $0.text.isEmpty } == true, "polish preload at start")
            check(!t.model.cleanupOff, "cleanup shown as on")
            var finished = false
            t.onFinished = { finished = true }
            t.stop()
            pump { finished && !t.model.summarizing }
            check(finished && fake.ended.count == 2, "stop ends both sessions, transcript finishes")
            check(fake.summaryCalls.count == 1 && t.model.summary?.points == ["Ship on Friday."], "summary requested and applied")
        }

        // 2. No cleanup model: finals stay final, nothing waits, no summary.
        do {
            let fake = EngineFake(capabilities: [])
            let t = meeting("no-cleanup", fake)
            check(t.model.segments.count == 2 && t.model.segments.allSatisfy { $0.stage == .final }, "segments stay final")
            check(fake.polishCalls.isEmpty, "no polish requests, no preload")
            check(t.model.cleanupOff, "UI flag says cleanup is off")
            var finished = false
            t.onFinished = { finished = true }
            t.stop()
            pump(2) { finished }
            check(finished && fake.summaryCalls.isEmpty && !t.model.summarizing && t.model.summary == nil, "finishes at once, no summary")
        }

        // 3. Polish but no summary capability; a polish that never answers must not block forever (10 s guard is real
        //    time, so only the capability path is checked here).
        do {
            let fake = EngineFake(capabilities: [.polish])
            fake.polishReply = { $0 }
            let t = meeting("polish-only", fake)
            var finished = false
            t.onFinished = { finished = true }
            t.stop()
            pump(2) { finished }
            check(finished && fake.summaryCalls.isEmpty && t.model.segments.allSatisfy { $0.stage == .polished }, "polish without summary")
        }

        // 4. A failed summary leaves the transcript alone.
        do {
            let fake = EngineFake()
            fake.polishReply = { $0 }
            let t = meeting("summary-fails", fake)
            var finished = false
            t.onFinished = { finished = true }
            t.stop()
            pump { finished && !t.model.summarizing }
            check(fake.summaryCalls.count == 1 && t.model.summary == nil && !t.model.summarizing, "failed summary is dropped")
        }

        // 5. The spelling pass runs on transcription finals (an alias from a vocabulary file).
        do {
            let vocab = dir.appendingPathComponent("vocabulary.md")
            let md = VocabularyFile.template.replacingOccurrences(of: "## Terms\n", with: "## Terms\n- pull request (heard as: pool request)\n")
            try? md.write(to: vocab, atomically: true, encoding: .utf8)
            check(SpellingPass.apply("please open a pool request", file: vocab) == "please open a pull request", "SpellingPass applies aliases")
        }

        // 6. Dictation: one .dictation session on the mic; partials and the final of that session only.
        do {
            let fake = EngineFake(capabilities: [])
            var flow = DictationFlow()
            fake.finalOnEnd = { .final($0, segment: 0, text: "um this is a test", lang: "en", start: nil, end: nil) }
            let id = flow.begin(fake, language: "")
            fake.push(id, pcm: Data(count: 3_200))
            let other = SessionID(channel: .mic, n: 99)
            check(flow.update(for: .partial(other, segment: 0, text: "stale", lang: nil)) == nil, "other session's partial ignored")
            check(flow.update(for: .partial(id, segment: 0, text: "this is", lang: "en")) == .partial("This is", lang: "en"), "partial shown")
            var inserted: [String] = []
            fake.onEvent = { e in
                if case .final(let text, _)? = flow.update(for: e) { inserted.append(text) }
            }
            flow.end(fake)
            check(fake.begun.count == 1 && fake.begun[0].kind == .dictation && fake.begun[0].channel == .mic, "dictation session on mic")
            check(fake.pushed[id] == 3_200 && fake.ended == [id], "audio pushed, session ended")
            check(inserted == ["This is a test"], "final cleaned for insertion (\(inserted))")
            flow.cancel(fake)
            check(fake.cancelled == [id] && flow.session == nil, "cancel drops the session")
            check(flow.update(for: .final(id, segment: 0, text: "late", lang: nil, start: nil, end: nil)) == nil, "late final after cancel ignored")
        }
        return ok
    }
}
