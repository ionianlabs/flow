import AppKit
import SwiftUI

/// Transcription mode: transcribes the mic ("You") and everything the Mac plays ("Them") into the
/// side panel and a Markdown file. Each stream is one ASR session for the whole meeting, cut into
/// segments at pauses: the recognizer keeps its context and language across cuts, only the text is
/// split (at the exact audio frame, see SpeechEngine.cut). A segment shows the live decoder's text
/// first, then the final text, then the local LLM's cleanup (only when the engine has the cleanup
/// model). The final text comes from Parakeet (FinalPass) once its model is loaded, otherwise from
/// the engine's live final.
enum Speaker: String {
    case you = "You", them = "Them"
}

struct TranscriptSegment: Identifiable, Equatable {
    enum Stage { case live, final, polished }
    let id: Int
    let speaker: Speaker
    /// First and last word, in the stream's audio time (estimates until the final arrives).
    var start: Date
    var end: Date
    var text: String
    var stage: Stage
    /// The recognizer's text before polish; echo detection compares against both.
    var heard = ""
}

final class TranscriptModel: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var started = Date()
    @Published var ended: Date?
    @Published var finishing = false
    @Published var level: Float = 0
    /// System audio level: stays flat while nothing plays, or while macOS withholds the permission.
    @Published var themLevel: Float = 0
    @Published var notice: String?
    @Published var fileURL: URL?
    @Published var summary: TranscriptSummary?
    /// The LLM is writing the summary of the finished transcript.
    @Published var summarizing = false
    /// The mic runs through macOS echo cancellation (speakers, not headphones).
    @Published var cancellingEcho = false
    /// The engine has no cleanup model: segments stay as heard and no summary is written.
    @Published var cleanupOff = false

    struct Block: Identifiable {
        let id: Int
        let speaker: Speaker
        let start: Date
        var segments: [TranscriptSegment]
    }

    /// Consecutive segments of one speaker form a block; a long monologue gets a new one every 2 minutes.
    func blocks(includeLive: Bool) -> [Block] {
        var out: [Block] = []
        for s in segments.sorted(by: { $0.start < $1.start }) where !s.text.isEmpty && (includeLive || s.stage != .live) {
            if let last = out.last, last.speaker == s.speaker, s.start.timeIntervalSince(last.start) < 120 {
                out[out.count - 1].segments.append(s)
            } else {
                out.append(Block(id: s.id, speaker: s.speaker, start: s.start, segments: [s]))
            }
        }
        return out
    }

    func reset() {
        segments = []
        started = Date()
        ended = nil
        finishing = false
        level = 0
        themLevel = 0
        notice = nil
        fileURL = nil
        summary = nil
        summarizing = false
    }
}

/// One audio source and its engine session.
private final class Stream {
    let speaker: Speaker
    let channel: Channel
    var segmenter = Segmenter()        // audio thread
    var samples = 0                    // audio thread: sent in this session
    var segment = 0                    // audio thread: current segment index
    var session: SessionID?            // main thread: this stream's engine session, nil when none is open
    var started = Date()               // main thread: when the session's audio began
    var segments: [Int: Int] = [:]     // main thread: segment index -> segment id, until final
    // Main thread, per segment index: the engine's final (text, language, audio times), and
    // Parakeet's text once it answered (nil inside: it failed). A segment is final with both.
    var liveFinals: [Int: (text: String, lang: String?, start: Double?, end: Double?)] = [:]
    var parakeet: [Int: String?] = [:]
    var awaitingParakeet: Set<Int> = []
    var audioSeconds: [Int: Double] = [:]  // main thread: length of the audio sent to Parakeet, per segment index
    // The current segment's audio for Parakeet: written on the audio thread, taken at cuts and at stop.
    private var pcm: [Int16] = []
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        data.withUnsafeBytes { pcm.append(contentsOf: $0.bindMemory(to: Int16.self)) }
        lock.unlock()
    }

    /// The audio up to `back` samples before the end; the rest starts the next segment.
    func take(keeping back: Int = 0) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let n = max(0, pcm.count - back)
        let out = Array(pcm[..<n])
        pcm.removeFirst(n)
        return out
    }

    func reset() {
        lock.lock()
        pcm = []
        lock.unlock()
        segments = [:]
        liveFinals = [:]
        parakeet = [:]
        awaitingParakeet = []
        audioSeconds = [:]
    }

    init(speaker: Speaker, channel: Channel) {
        self.speaker = speaker
        self.channel = channel
    }
}

final class Transcriber {
    let model = TranscriptModel()
    private(set) var isActive = false
    /// Called once everything is final and saved after stop().
    var onFinished: () -> Void = {}

    private let mic: AudioCapture
    private let system = SystemAudioCapture()
    private let engine: SpeechEngine
    private let you = Stream(speaker: .you, channel: .mic)
    private let them = Stream(speaker: .them, channel: .system)
    private var nextID = 1
    private var polishing: Set<Int> = []
    private var finishTimeout: DispatchWorkItem?
    let finalPass = FinalPass()
    private var summaryID = 0
    private var pendingSummaries: [Int: URL] = [:]  // summary request -> its transcript file
    /// The cleanup model is downloaded: segments get polished, the transcript a summary.
    var cleanupAvailable: Bool { !cleanupDisabled && engine.capabilities.contains(.polish) }
    /// --transcribetest --no-polish: score the Parakeet finals themselves; the LLM's wording varies run to run.
    var cleanupDisabled = false

    init(engine: SpeechEngine, mic: AudioCapture) {
        self.mic = mic
        self.engine = engine
    }

    func start() throws {
        guard !isActive else { return }
        model.reset()
        nextID = 1
        polishing = []
        you.reset()
        them.reset()
        model.cleanupOff = !cleanupAvailable
        if cleanupAvailable { engine.polish(id: 0, text: "", before: "") }  // load the LLM while the first segment is spoken
        Task { await Segmenter.prepare() }  // pause detection; the energy gate cuts until it's loaded
        if !finalPass.isReady { finalPass.prepare() }  // takes over from the next segment once loaded

        mic.warmSeconds = 0
        mic.onLevel = { [model] level in
            DispatchQueue.main.async { model.level = 0.5 * model.level + 0.5 * level }
        }
        model.cancellingEcho = Settings.cancelEcho && AudioDevices.outputIsSpeakers()
        try mic.begin(device: AudioDevices.resolve(Settings.microphone), cancelEcho: model.cancellingEcho)
        isActive = true
        begin(you)
        mic.onAudio = { [weak self, you] pcm in self?.feed(you, pcm) }

        do {
            begin(them)
            system.onAudio = { [weak self, them, model] pcm in
                let level = Segmenter.rms(pcm)
                DispatchQueue.main.async { model.themLevel = 0.5 * model.themLevel + 0.5 * level }
                self?.feed(them, pcm)
            }
            try system.start()
        } catch {
            NSLog("Ionian Flow: system audio failed: %@", error.localizedDescription)
            model.notice = "System audio is unavailable. Only your mic is transcribed."
            closeSession(them, cancel: true)
        }
        save()
    }

    /// Stops capturing; the panel shows "Finishing…" until the last finals and polishes are in.
    func stop() {
        guard isActive else { return }
        isActive = false
        mic.onAudio = { _ in }
        mic.onLevel = { _ in }
        mic.finish()
        system.onAudio = { _ in }
        system.stop()
        finishSegment(you, index: you.segment, audio: you.take())
        closeSession(you, cancel: false)
        if them.session != nil {
            finishSegment(them, index: them.segment, audio: them.take())
            closeSession(them, cancel: false)
        }
        model.finishing = true
        model.level = 0
        model.themLevel = 0
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        finishIfDone()
    }

    /// The engine's events: true if they belonged to transcription.
    func handleMain(_ event: EngineEvent) -> Bool {
        switch event {
        case .partial(let id, _, _, _), .final(let id, _, _, _, _, _):
            guard let stream = [you, them].first(where: { $0.session == id }) else { return false }
            handle(event, from: stream)
            return true
        case .polished:  // only transcription asks for polish
            handle(event, from: you)
            return true
        case .summary(let id, let summary):
            addSummary(id: id, summary)
            return true
        default:
            return false
        }
    }

    /// --transcribetest: the streams without capture devices, fed by `feedFile`; the Markdown goes to `file`.
    func startForFiles(them withThem: Bool, file: URL) {
        model.reset()
        model.fileURL = file
        nextID = 1
        polishing = []
        model.cleanupOff = !cleanupAvailable
        if cleanupAvailable { engine.polish(id: 0, text: "", before: "") }
        isActive = true
        begin(you)
        if withThem { begin(them) }
    }

    /// --transcribetest: one chunk of 16 kHz mono Int16, from the thread that stands in for the audio thread.
    func feedFile(_ speaker: Speaker, _ pcm: Data) {
        feed(speaker == .you ? you : them, pcm)
    }

    // MARK: - Audio thread

    private func feed(_ stream: Stream, _ pcm: Data) {
        guard let session = stream.session else { return }
        engine.push(session, pcm: pcm)
        stream.append(pcm)
        stream.samples += pcm.count / 2
        guard let back = stream.segmenter.feed(pcm) else { return }
        let at = stream.samples - back
        engine.cut(session, at: at)
        let audio = stream.take(keeping: back)
        stream.segment += 1
        let index = stream.segment
        DispatchQueue.main.async { [self] in
            finishSegment(stream, index: index - 1, audio: audio)
            addSegment(stream, index: index, at: at)
        }
    }

    // MARK: - Main thread

    /// Starts the stream's ASR session; it runs until stop().
    private func begin(_ stream: Stream) {
        stream.samples = 0
        stream.segment = 0
        stream.segmenter = Segmenter()
        stream.reset()
        stream.started = Date()
        let language = Settings.language == "auto" ? "" : Settings.language
        stream.session = engine.beginSession(SessionOptions(language: language, channel: stream.channel, kind: .transcription))
        addSegment(stream, index: 0, at: 0)
    }

    /// Ends the stream's engine session (its last final still arrives) or drops it.
    private func closeSession(_ stream: Stream, cancel: Bool) {
        guard let session = stream.session else { return }
        if cancel {
            engine.cancel(session)
            stream.session = nil
        } else {
            engine.end(session)
        }
    }

    /// A segment's audio is complete: Parakeet transcribes it, if it's loaded (in a segment that
    /// ended before it was, the engine's live final stands).
    private func finishSegment(_ stream: Stream, index: Int, audio: [Int16]) {
        guard finalPass.isReady, stream.segments[index] != nil, audio.count >= 3_200 else { return }
        stream.awaitingParakeet.insert(index)
        stream.audioSeconds[index] = Double(audio.count) / 16_000
        finalPass.transcribe(audio) { [weak self] text in
            stream.awaitingParakeet.remove(index)
            stream.parakeet[index] = .some(text)
            self?.finalize(stream, index: index)
        }
    }

    private func addSegment(_ stream: Stream, index: Int, at sample: Int) {
        let id = nextID
        nextID += 1
        stream.segments[index] = id
        let start = stream.started.addingTimeInterval(Double(sample) / 16_000)
        model.segments.append(TranscriptSegment(id: id, speaker: stream.speaker, start: start, end: start,
                                                text: "", stage: .live))
    }

    private func handle(_ event: EngineEvent, from stream: Stream) {
        switch event {
        case .partial(let session, let segment, let text, let lang):
            guard session == stream.session, let id = stream.segments[segment] else { return }
            update(id) { $0.end = max($0.end, Date()) }  // until the final has the audio time
            let clean = withoutEcho(FillerFilter.clean(text, lang: lang), segment: id)
            update(id) { if $0.stage == .live { $0.text = clean } }
        case .final(let session, let segment, let text, let lang, let start, let end):
            guard session == stream.session, stream.segments[segment] != nil else { return }
            stream.liveFinals[segment] = (text, lang, start, end)
            finalize(stream, index: segment)
        case .polished(let id, let text):
            guard id != 0 else { return }
            polishing.remove(id)
            if !text.isEmpty { update(id) { $0.text = text; $0.stage = .polished } }
            removeEchoes()
            save()
            finishIfDone()
        default:
            break
        }
    }

    /// Once the engine's final (audio times; text when Parakeet isn't used or failed) and Parakeet's
    /// answer, if it was asked, are both in.
    private func finalize(_ stream: Stream, index: Int) {
        guard let live = stream.liveFinals[index], !stream.awaitingParakeet.contains(index),
              let id = stream.segments[index] else { return }
        stream.segments[index] = nil
        stream.liveFinals[index] = nil
        let text = (stream.parakeet.removeValue(forKey: index) ?? nil) ?? live.text
        let seconds = stream.audioSeconds.removeValue(forKey: index)
        if let start = live.start, let end = live.end {
            update(id) {
                $0.start = stream.started.addingTimeInterval(start)
                $0.end = stream.started.addingTimeInterval(end)
            }
        } else if let seconds {
            // The live decoder heard no word here (Parakeet may have): without word times the end would stay
            // at the wall time of the last partial. The segment's own audio length gives it.
            update(id) { $0.end = $0.start.addingTimeInterval(seconds) }
        }
        // The spelling pass runs here for every final: the engine only delivers recognizer text.
        // (Dictation gets it inside the engine's DictationFinal, so it is not applied twice there.)
        let heard = FillerFilter.clean(SpellingPass.apply(text), lang: live.lang)
        let clean = withoutEcho(heard, segment: id)
        if clean.isEmpty {
            model.segments.removeAll { $0.id == id }
        } else {
            // The previous segment of the same speaker: a sentence split by a pause stays one.
            let before = model.segments.last { $0.speaker == stream.speaker && $0.id < id && $0.stage != .live }
            update(id) { $0.text = clean; $0.heard = heard; $0.stage = .final }
            if cleanupAvailable {
                polishing.insert(id)
                engine.polish(id: id, text: clean, before: before?.text ?? "")
            }
        }
        if stream === them { removeEchoes() }  // "You" may have finished first
        save()
        finishIfDone()
    }

    // MARK: - Echo removal

    /// Without headphones the mic also hears the speakers, so what "Them" said shows up again under
    /// "You", often mixed with your own words when you talk over someone. See `stripEcho`.
    /// Only "Them" segments that overlap in time count (3 s of slack for the two streams' delays).
    private func withoutEcho(_ text: String, segment id: Int) -> String {
        guard let seg = model.segments.first(where: { $0.id == id }), seg.speaker == .you else { return text }
        let theirs = model.segments
            .filter { $0.speaker == .them && $0.start.timeIntervalSince(seg.end) < 3 && seg.start.timeIntervalSince($0.end) < 3 }
            .flatMap { [$0.text, $0.heard] }
        return Self.stripEcho(text, theirs: theirs)
    }

    /// Cuts runs of 3+ words that also occur in `theirs` (bridging one misheard word), plus 2-word
    /// pieces of `theirs` touching such a run or the text's ends. What's left is yours; a single
    /// leftover word between echoes is usually a recognition error and goes too.
    static func stripEcho(_ text: String, theirs: [String]) -> String {
        var tri = Set<String>(), bi = Set<String>()
        for t in theirs {
            let w = words(t)
            for i in w.indices.dropLast(1) { bi.insert(w[i] + " " + w[i + 1]) }
            for i in w.indices.dropLast(2) { tri.insert(w[i..<i + 3].joined(separator: " ")) }
        }
        let tokens = text.split(separator: " ").map(String.init)
        let norm = tokens.map { words($0).joined() }
        let n = tokens.count
        guard !tri.isEmpty, n >= 3 else { return text }
        var echo = [Bool](repeating: false, count: n)
        for i in 0...(n - 3) where tri.contains(norm[i..<i + 3].joined(separator: " ")) {
            echo[i] = true; echo[i + 1] = true; echo[i + 2] = true
        }
        guard echo.contains(true) else { return text }
        for i in 1..<(n - 1) where !echo[i] && echo[i - 1] && echo[i + 1] { echo[i] = true }
        for i in 0..<(n - 1) where !echo[i] && !echo[i + 1] && bi.contains(norm[i] + " " + norm[i + 1]) {
            let touches = i == 0 || i + 1 == n - 1 || echo[i - 1] || (i + 2 < n && echo[i + 2])
            if touches { echo[i] = true; echo[i + 1] = true }
        }
        var kept: [String] = [], run: [String] = []
        for i in 0..<n {
            if !echo[i] { run.append(tokens[i]) }
            if echo[i] || i == n - 1 {
                if run.count >= 2 { kept += run }
                run = []
            }
        }
        var out = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        if let first = out.first, first.isLowercase { out = first.uppercased() + out.dropFirst() }
        return out
    }

    static func echoSelfTest() -> Bool {
        let them = ["Hey, can you review the pull request before launch? I think the streaming latency looks really good now."]
        let cases: [(String, String)] = [
            ("Hey can you review the pull request before launch", ""),
            ("Hey can you review the pull request yes I'll do it before launch", "Yes I'll do it"),
            ("Hey can you review the full request before launch", ""),  // one misheard word inside
            ("Sure, I'll review it after lunch.", "Sure, I'll review it after lunch."),
            ("I think the streaming latency looks really good now, but the build is slow", "But the build is slow"),
            ("Ja genau, das machen wir so.", "Ja genau, das machen wir so."),
        ]
        var ok = true
        for (input, want) in cases {
            let got = stripEcho(input, theirs: them)
            print(got == want ? "PASS" : "FAIL", " echo: \(input)  ->  \(got)")
            ok = ok && got == want
        }
        return ok
    }

    /// Re-checks finished "You" segments once more "Them" text is in.
    private func removeEchoes() {
        for seg in model.segments where seg.speaker == .you && seg.stage != .live {
            let kept = withoutEcho(seg.text, segment: seg.id)
            if kept != seg.text { update(seg.id) { $0.text = kept } }
        }
        withAnimation(.smooth(duration: 0.35)) {
            model.segments.removeAll { $0.speaker == .you && $0.stage != .live && $0.text.isEmpty }
        }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func update(_ id: Int, _ change: (inout TranscriptSegment) -> Void) {
        guard let i = model.segments.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.smooth(duration: 0.35)) { change(&model.segments[i]) }
    }

    private func finishIfDone() {
        guard model.finishing, you.segments.isEmpty, them.segments.isEmpty, polishing.isEmpty else { return }
        finish()
    }

    /// Final state: unfinished segments keep their best text; the file is written one last time.
    func finish() {
        guard model.finishing else { return }
        finishTimeout?.cancel()
        finishTimeout = nil
        model.segments.removeAll { $0.text.isEmpty }
        for i in model.segments.indices where model.segments[i].stage == .live { model.segments[i].stage = .final }
        you.reset()
        them.reset()
        you.session = nil
        them.session = nil
        polishing = []
        model.finishing = false
        model.ended = Date()
        save()
        requestSummary()
        onFinished()
    }

    /// The finished transcript goes to the LLM for its frontmatter and summary; the file gets them
    /// when they arrive (also if a new transcription has started meanwhile).
    private func requestSummary() {
        guard Settings.summarizeTranscripts, engine.capabilities.contains(.summary),
              !model.segments.isEmpty, let url = model.fileURL else { return }
        summaryID += 1
        let id = summaryID
        pendingSummaries[id] = url
        model.summarizing = true
        let transcript = TranscriptStore.body(model)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tags = VaultTags.common()
            DispatchQueue.main.async { self?.engine.summarize(id: id, transcript: transcript, tags: tags) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.addSummary(id: id, nil) }
    }

    private func addSummary(id: Int, _ summary: TranscriptSummary?) {
        guard let url = pendingSummaries.removeValue(forKey: id) else { return }
        if model.fileURL == url {
            model.summarizing = false
            guard let summary else { return }
            model.summary = summary
            save()
        } else if let summary, let text = try? String(contentsOf: url, encoding: .utf8) {
            try? TranscriptStore.insert(summary, into: text).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func save() {
        do {
            model.fileURL = try TranscriptStore.save(model)
        } catch {
            NSLog("Ionian Flow: saving transcript failed: %@", error.localizedDescription)
            model.notice = "Could not save the transcript. \(error.localizedDescription)"
        }
    }
}

/// Markdown files in `Settings.transcriptsFolder`, rewritten atomically after every finished
/// segment: a crash loses at most the segment being spoken. A transcript stays in the folder it
/// started in, even if the setting changes meanwhile.
enum TranscriptStore {
    static func save(_ model: TranscriptModel) throws -> URL {
        let url = model.fileURL ?? Settings.transcriptsFolder
            .appendingPathComponent(format(model.started, "yyyy-MM-dd HH-mm") + ".md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown(model).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// YAML frontmatter (so notes tools and LLMs can find the meeting by date, topic or name), the
    /// title, the summary once there is one, then the transcript.
    static func markdown(_ model: TranscriptModel) -> String {
        let end = model.ended.map { " to " + format($0, "HH:mm") } ?? " · recording"
        let out = frontmatter(model) + "# Transcript · \(format(model.started, "d MMM yyyy, HH:mm"))\(end)\n" + body(model)
        return model.summary.map { insert($0, into: out) } ?? out
    }

    /// The speaker blocks only: what the summary is made from.
    static func body(_ model: TranscriptModel) -> String {
        model.blocks(includeLive: false).map { block in
            "\n**\(block.speaker.rawValue)** · \(format(block.start, "HH:mm"))\n"
                + block.segments.map(\.text).joined(separator: " ") + "\n"
        }.joined()
    }

    static func frontmatter(_ model: TranscriptModel) -> String {
        var lines = ["---", "type: transcript", "date: \(format(model.started, "yyyy-MM-dd"))",
                     "start: \"\(format(model.started, "HH:mm"))\""]
        if let ended = model.ended {
            lines += ["end: \"\(format(ended, "HH:mm"))\"",
                      "duration: \(max(1, Int(ended.timeIntervalSince(model.started) / 60 + 0.5))) min"]
        }
        let speakers = [Speaker.you, .them].filter { s in model.segments.contains { $0.speaker == s } }
        if !speakers.isEmpty { lines.append("speakers: [\(speakers.map(\.rawValue).joined(separator: ", "))]") }
        return (lines + ["---", ""]).joined(separator: "\n")
    }

    /// Adds the summary's keys to the frontmatter and its section under the title.
    static func insert(_ s: TranscriptSummary, into text: String) -> String {
        guard !text.contains("\n## Summary\n") else { return text }
        var lines = text.components(separatedBy: "\n")
        var keys: [String] = []
        if !s.description.isEmpty { keys.append("description: \(quoted(s.description))") }
        if !s.tags.isEmpty { keys.append("tags: [\(s.tags.joined(separator: ", "))]") }
        if !s.keywords.isEmpty { keys.append("keywords: [\(s.keywords.map(quoted).joined(separator: ", "))]") }
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            lines.insert(contentsOf: keys, at: close)
        } else {
            lines.insert(contentsOf: ["---"] + keys + ["---"], at: 0)
        }
        var section = ["", "## Summary"] + s.points.map { "- " + $0 }
        if !s.decisions.isEmpty { section += ["", "**Decisions**"] + s.decisions.map { "- " + $0 } }
        if !s.actions.isEmpty { section += ["", "**Action items**"] + s.actions.map { "- " + $0 } }
        section += ["", "## Transcript"]
        if let title = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines.insert(contentsOf: section, at: title + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// A YAML double-quoted string (JSON's escaping is valid YAML).
    private static func quoted(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// The spelling pass (vocabulary aliases, spelling variants, near misses) for transcription finals.
/// Follows the vocabulary file: rebuilt when it changes, and off with "Use vocabulary" switched off.
enum SpellingPass {
    private static var cached: (stamp: Date, normalizer: VocabNormalizer)?

    static func apply(_ text: String, file: URL = Settings.vocabularyFile) -> String {
        guard Settings.useVocabulary else { return text }
        return normalizer(file)?.normalize(text) ?? text
    }

    private static func normalizer(_ file: URL) -> VocabNormalizer? {
        guard let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        if let cached, cached.stamp == stamp { return cached.normalizer }
        guard let md = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let n = VocabNormalizer(markdown: md)
        cached = (stamp, n)
        return n
    }
}

/// Dictation's engine side: one .dictation session per key press. The engine's final already went
/// through DictationFinal (Parakeet, rescoring, spelling pass), so only the display cleanup is left.
struct DictationFlow {
    enum Update: Equatable {
        case partial(String, lang: String?)
        case final(String, lang: String?)
    }

    private(set) var session: SessionID?
    /// The detected language of this dictation so far.
    var lang: String?

    mutating func begin(_ engine: SpeechEngine, language: String) -> SessionID {
        let id = engine.beginSession(SessionOptions(language: language, channel: .mic, kind: .dictation))
        session = id
        lang = nil
        return id
    }

    /// The release: the final is still to come.
    func end(_ engine: SpeechEngine) {
        if let session { engine.end(session) }
    }

    mutating func cancel(_ engine: SpeechEngine) {
        if let session { engine.cancel(session) }
        session = nil
    }

    /// Events of this session only; older sessions' and other kinds are ignored.
    mutating func update(for event: EngineEvent) -> Update? {
        switch event {
        case .partial(let id, _, let text, let l):
            guard id == session else { return nil }
            if let l { lang = l }
            return .partial(Self.clean(text, lang: l ?? lang), lang: l)
        case .final(let id, _, let text, let l, _, _):
            guard id == session else { return nil }
            let language = l ?? lang
            return .final(Self.clean(text, lang: language), lang: language)
        default:
            return nil
        }
    }

    /// Same cleanup for the live HUD and the paste, so what you see is what gets inserted.
    static func clean(_ text: String, lang: String?) -> String {
        TextFormatter.format(FillerFilter.clean(text, lang: lang))
    }
}
