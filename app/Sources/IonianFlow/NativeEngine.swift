import FluidAudio
import Foundation

// Unit B (live). NativeEngine: the SpeechEngine implementation. Owns sessions (SessionID counters per channel),
// event delivery on main, capabilities (.polish/.summary when ModelHub.gemmaAvailable), dictation sessions
// (buffer PCM, call an UtteranceFinalizer on end()), and forwarding polish/summarize to Polisher/Summarizer.
// Streaming itself lives in NativeLive.swift (LiveStream).
//
// Differences from asr/server.py's Session, on purpose:
//  - Live text only (the ";live" mode the app used for transcription). The second, slower final decoder is gone:
//    dictation finals come from the UtteranceFinalizer, transcription finals are the live finals.
//  - `lang` is the manager's first detected language tag of the session (FluidAudio exposes only that one);
//    server.py reports the last tag it saw in the segment.
//  - Vocabulary spelling (VocabNormalizer) is not applied here: the app runs it on finals.

/// Terms for the live bias, read from the vocabulary file (server.py/boost.py: up to 1,000 terms, 2+ letters).
final class LiveVocabulary: @unchecked Sendable {
    static let maxTerms = 1000
    static let minLetters = 2
    /// Phase 0 (scripts/engine-bench vocab, 560 ms chunks): a flat 4.5 per token, FluidAudio's default, recalled the
    /// most terms (43 % vs 28 % off, python boost 66 % with spelling pass) and lowered control WER (16.4 vs 22.4).
    static let weight: Float = 4.5

    private let url: URL?
    private let lock = NSLock()
    private var mtime: Date?
    private var loaded = false
    private var dirty = false
    private(set) var version = 0
    private var terms: [CustomVocabularyTerm] = []

    init(url: URL?) { self.url = url }

    /// Marks the file as changed; the next session start re-reads it.
    func invalidate() { lock.lock(); dirty = true; lock.unlock() }

    /// Re-reads the file when it changed (one stat), like server.py's refresh_vocabulary at session start.
    func current() -> (version: Int, terms: [CustomVocabularyTerm]) {
        lock.lock(); defer { lock.unlock() }
        let m = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        if !loaded || dirty || m != mtime {
            loaded = true; dirty = false; mtime = m
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            terms = Self.terms(from: VocabularyParser.parse(text).terms.map(\.text))
            version += 1
        }
        return (version, terms)
    }

    static func terms(from texts: [String]) -> [CustomVocabularyTerm] {
        var seen = Set<String>(), out: [CustomVocabularyTerm] = []
        for t in texts {
            guard t.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= minLetters,
                  seen.insert(t.lowercased()).inserted else { continue }
            out.append(CustomVocabularyTerm(text: t, weight: weight))
            if out.count == maxTerms { break }
        }
        return out
    }
}

final class NativeEngine: SpeechEngine, @unchecked Sendable {
    private let hub: ModelHub
    private let finalizer: UtteranceFinalizer?
    private let vocabulary: LiveVocabulary
    private let lock = NSLock()
    private var handler: (EngineEvent) -> Void = { _ in }
    private var counters: [Channel: Int] = [:]
    private var active: [Channel: LiveStream] = [:]  // the session not ended yet, per channel
    private var applied: [Channel: Int] = [:]  // vocabulary version in each channel's manager
    private var lanes: [Channel: SerialGate] = [.mic: SerialGate(), .system: SerialGate()]
    private var _ready = false
    private var stopped = false
    private var polisher: Polisher?
    private var summarizer: Summarizer?

    /// Always delivered on main.
    var onEvent: (EngineEvent) -> Void {
        get { handler }
        set { handler = newValue }
    }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return _ready }
    var capabilities: EngineCapabilities {
        hub.gemmaAvailable() ? [.polish, .summary] : []
    }

    /// `finalizer` is Unit C's ParakeetFinalizer in the app; tests may pass a fake. Without one, dictation
    /// finals are the live text. `useVocabulary`: false turns the live bias off (Settings.useVocabulary).
    init(hub: ModelHub = .shared, finalizer: UtteranceFinalizer? = nil,
         vocabularyURL: URL? = Settings.vocabularyFile, useVocabulary: Bool = true) {
        self.hub = hub
        self.finalizer = finalizer
        self.vocabulary = LiveVocabulary(url: useVocabulary ? vocabularyURL : nil)
    }

    // MARK: Events

    private func emit(_ event: EngineEvent) {
        DispatchQueue.main.async { [self] in
            lock.lock(); let off = stopped; lock.unlock()
            if !off { onEvent(event) }
        }
    }

    // MARK: Lifecycle

    /// Loads the microphone model in the background and announces .ready. The system-audio model loads at its
    /// first session.
    func start() {
        lock.lock(); stopped = false; lock.unlock()
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let manager = try await hub.nemotron(.mic)
                await prepare(manager, channel: .mic)
                lock.withLock { _ready = true }
                emit(.ready)
            } catch {
                emit(.error(error as? EngineError ?? .failed("\(error)")))
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        _ready = false  // start() announces .ready again
        let streams = Array(active.values)
        active = [:]
        lock.unlock()
        for s in streams { s.cancel() }
    }

    /// Applies the live bias to a manager when the vocabulary changed since it last got one.
    private func prepare(_ manager: StreamingNemotronMultilingualAsrManager, channel: Channel) async {
        let (version, terms) = vocabulary.current()
        let have = lock.withLock { applied[channel] }
        guard have != version else { return }
        await manager.setCustomVocabulary(terms)
        lock.withLock { applied[channel] = version }
    }

    // MARK: Sessions

    func beginSession(_ o: SessionOptions) -> SessionID {
        lock.lock()
        let n = (counters[o.channel] ?? 0) + 1
        counters[o.channel] = n
        let id = SessionID(channel: o.channel, n: n)
        let previous = active[o.channel]
        let lane = lanes[o.channel]!
        lock.unlock()
        previous?.cancel()  // like server.py: a new session ends an open one on the same stream, silently

        let hub = hub, channel = o.channel
        let deps = LiveStream.Dependencies(
            manager: { try await hub.nemotron(channel) },
            prepare: { [self] manager in await prepare(manager, channel: channel) },
            lane: lane,
            finalize: o.kind == .dictation ? finalizer.map { f in { pcm, lang in await f.finalize(pcm: pcm, lang: lang) } } : nil,
            emit: { [self] in emit($0) })
        let stream = LiveStream(id: id, options: o, deps: deps)
        lock.lock(); active[o.channel] = stream; sessions[id] = stream; lock.unlock()
        return id
    }

    private var sessions: [SessionID: LiveStream] = [:]

    private func stream(_ s: SessionID) -> LiveStream? { lock.lock(); defer { lock.unlock() }; return sessions[s] }

    private func finish(_ s: SessionID, _ stream: LiveStream) {
        lock.lock()
        sessions[s] = nil
        if active[s.channel] === stream { active[s.channel] = nil }
        lock.unlock()
    }

    func push(_ s: SessionID, pcm: Data) { stream(s)?.push(pcm) }
    func cut(_ s: SessionID, at sample: Int) { stream(s)?.cut(at: sample) }

    func end(_ s: SessionID) {
        guard let st = stream(s) else { return }
        st.end()
        finish(s, st)
    }

    func cancel(_ s: SessionID) {
        guard let st = stream(s) else { return }
        st.cancel()
        finish(s, st)
    }

    func reloadVocabulary() { vocabulary.invalidate() }

    // MARK: Cleanup model

    func polish(id: Int, text: String, before: String) {
        lock.lock()
        if polisher == nil { polisher = Polisher(hub: hub) }
        let p = polisher!
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            if id == 0, text.isEmpty { await p.preload(); return }
            // On failure the caller keeps its own text: send it back so nothing waits for a reply.
            let out = await p.polish(text: text, before: before)
            emit(.polished(id: id, text: out ?? text))
        }
    }

    func summarize(id: Int, transcript: String, tags: [String]) {
        lock.lock()
        if summarizer == nil { summarizer = Summarizer(hub: hub) }
        let s = summarizer!
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            emit(.summary(id: id, await s.summarize(transcript: transcript, tags: tags)))
        }
    }
}
