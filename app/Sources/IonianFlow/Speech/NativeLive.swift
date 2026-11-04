import FluidAudio
import Foundation

// Unit B (live). Streaming Nemotron: one LiveStream per session, behaviour-equal to the Session class in
// the former Python server.py (live decoder only, like its ";live" start option): cuts at sample/1280 encoder frames,
// PUNCT_HOLD 8, leading-punctuation strip, Latin-only, flush padding, segment times, language tag.
//
// Two parts. SegmentTracker is the pure text/cut logic (the port of server.py's LiveStreamer; no models,
// covered by selfTest). LiveStream drives one StreamingNemotronMultilingualAsrManager and feeds the tracker.
//
// Concurrency: each channel has one lane (a SerialGate) that serialises the sessions using that channel's
// manager. The managers are NOT put through ModelHub.serial: each belongs to exactly one stream, and the
// coexistence bench ran two Nemotron streams next to Parakeet, CTC and Gemma for 30 minutes without errors.
// Holding the shared lane for every 100 ms push would also make a polish (seconds) stall live partials.

/// One emitted token: its encoder frame (80 ms) in session audio and its raw SentencePiece piece ("▁" starts a word).
struct LiveToken: Equatable {
    let frame: Int
    let piece: String
}

enum SegmentOut: Equatable {
    case text(segment: Int, text: String)
    /// A segment is complete. first/last: encoder frames of its first and last word token (nil when it has none).
    case cut(segment: Int, text: String, first: Int?, last: Int?)
}

/// Port of server.py's LiveStreamer: splits the token stream into segments at the session's cuts.
struct SegmentTracker {
    static let frameSamples = 1280  // one encoder frame: 80 ms at 16 kHz
    /// The recognizer writes a sentence's full stop a few frames after the last word, which can be past the
    /// cut: punctuation this soon after a cut (0.64 s), before any word, still ends the previous segment.
    static let punctHold = 8

    private(set) var cuts: [Int] = []
    private(set) var pending: [LiveToken] = []
    private(set) var frame = 0
    private(set) var segment = 0

    // MARK: Pieces

    /// A piece without a letter or digit (lone punctuation, a lone "▁").
    static func isPunct(_ piece: String) -> Bool {
        !piece.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// A letter outside Basic Latin, Latin-1, Latin Extended-A/B and Latin Extended Additional (server.py NON_LATIN).
    static func hasNonLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            CharacterSet.letters.contains(u) && !(u.value <= 0x24F || (0x1E00...0x1EFF).contains(u.value))
        }
    }

    /// server.py clean(): "▁" to a space, whitespace runs to one, trimmed.
    static func decode(pieces: [String]) -> String {
        let joined = pieces.joined().replacingOccurrences(of: "▁", with: " ")
        return joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func decode(_ tokens: ArraySlice<LiveToken>) -> String { decode(pieces: tokens.map(\.piece)) }

    /// What the segment shows: punctuation that slipped past the cut ended the previous segment.
    static func display(_ text: String, segment: Int) -> String {
        guard segment > 0 else { return text }
        let strip: Set<Character> = [".", ",", ";", ":", "!", "?", "…", " "]
        return String(text.drop(while: { strip.contains($0) }))
    }

    // MARK: Cuts

    /// server.py Session.cut: at least one frame after the previous cut, and never frame 0.
    mutating func addCut(sample: Int) {
        cuts.append(max(sample / Self.frameSamples, (cuts.last.map { $0 + 1 }) ?? 1))
    }

    // MARK: Streaming

    /// First index of a word token at or after frame `at`: where the next segment starts.
    private func split(at: Int) -> Int? {
        pending.firstIndex { $0.frame >= at && !Self.isPunct($0.piece) }
    }

    /// The current segment's tokens: not the next segment's words while a cut waits for punctuation.
    private func visible() -> ArraySlice<LiveToken> {
        if segment < cuts.count, let i = split(at: cuts[segment]) { return pending[..<i] }
        return pending[...]
    }

    /// Ends segments whose cut the decoder is past: at the next word after the cut, or once punctHold frames
    /// passed without one. A cut can also arrive after the decoder passed it; tokens behind it move on.
    private mutating func settle(force: Bool) -> [SegmentOut] {
        var out: [SegmentOut] = []
        while segment < cuts.count {
            let at = cuts[segment]
            let i = split(at: at)
            if i == nil, frame < at + Self.punctHold, !force { break }
            let n = i ?? pending.count
            let done = Array(pending[..<n])
            pending.removeFirst(n)
            out.append(emitCut(done))
            segment += 1
        }
        return out
    }

    private func emitCut(_ done: [LiveToken]) -> SegmentOut {
        let words = done.filter { !Self.isPunct($0.piece) }  // a trailing "?" can come ~1 s late
        return .cut(segment: segment, text: Self.display(Self.decode(done[...]), segment: segment),
                    first: words.first?.frame, last: words.last?.frame)
    }

    /// One decoder step (server.py LiveStreamer.put): the tokens that arrived and the number of encoder frames
    /// decoded so far. Emits finished segments, then the current text when something changed.
    mutating func step(tokens: [LiveToken], frames: Int) -> [SegmentOut] {
        frame = max(frame, frames)
        pending += tokens
        var out = settle(force: false)
        if !out.isEmpty || !tokens.isEmpty {
            out.append(.text(segment: segment, text: Self.display(Self.decode(visible()), segment: segment)))
        }
        return out
    }

    /// End of the session: every open cut ends, then the last segment.
    mutating func end(tokens: [LiveToken]) -> [SegmentOut] {
        pending += tokens
        var out = settle(force: true)
        out.append(emitCut(pending))
        pending = []
        return out
    }

    /// Seconds of session audio for a frame (server.py: round(f * 1280 / sr, 2)).
    static func seconds(_ frame: Int?) -> Double? {
        frame.map { (Double($0 * frameSamples) / 16000 * 100).rounded() / 100 }
    }
}

/// Language for the manager's prompt: "" and "auto" stay auto, "de" becomes "de-DE", "en" "en-US".
func nativeLanguageCode(_ language: String) -> String {
    switch language {
    case "", "auto": return "auto"
    case "de": return "de-DE"
    case "en": return "en-US"
    default: return language
    }
}

/// One session on one channel. Commands are queued as they arrive (audio-thread safe); one task feeds them to
/// the channel's manager once the lane is free and the model is loaded.
final class LiveStream: @unchecked Sendable {
    enum Command { case audio(Data, queued: Date), cut(Int), end, cancel }

    struct Dependencies: @unchecked Sendable {
        /// The channel's warmed manager (ModelHub.nemotron).
        var manager: @Sendable () async throws -> StreamingNemotronMultilingualAsrManager
        /// Called with the manager before the first audio: applies the live vocabulary bias.
        var prepare: @Sendable (StreamingNemotronMultilingualAsrManager) async -> Void
        /// Serialises the sessions of one channel.
        var lane: SerialGate
        /// Dictation only: whole-utterance final. Empty means "use the live text".
        var finalize: (@Sendable ([Float], String?) async -> String)?
        var emit: @Sendable (EngineEvent) -> Void
    }

    /// Silence pushed after the last audio so the last chunk and its right context come through
    /// (server.py: chunk + streaming latency + 0.1 s; the chunk is 560 ms here).
    static let flushSeconds = 0.56 + 0.56 + 0.1

    let id: SessionID
    private let options: SessionOptions
    private let commands: AsyncStream<Command>
    private let continuation: AsyncStream<Command>.Continuation
    private let lock = NSLock()
    private var _cancelled = false
    private var _ended = false

    init(id: SessionID, options: SessionOptions, deps: Dependencies) {
        self.id = id
        self.options = options
        var c: AsyncStream<Command>.Continuation!
        commands = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        Task.detached(priority: .userInitiated) { [self] in await run(deps) }
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    /// end() or cancel() was called: no more audio is accepted.
    var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return _ended }

    func push(_ pcm: Data) { if !isEnded { continuation.yield(.audio(pcm, queued: Date())) } }
    func cut(at sample: Int) { if !isEnded { continuation.yield(.cut(sample)) } }
    func end() {
        lock.lock(); let was = _ended; _ended = true; lock.unlock()
        if !was { continuation.yield(.end); continuation.finish() }
    }
    func cancel() {
        lock.lock(); _cancelled = true; let was = _ended; _ended = true; lock.unlock()
        continuation.yield(.cancel)
        if !was { continuation.finish() }
    }

    private func run(_ deps: Dependencies) async {
        let dictation = options.kind == .dictation
        var finals: [(segment: Int, text: String, start: Double?, end: Double?)] = []
        var lang: String?
        var utterance: [Float] = []
        // Dictation: the finalizer starts at the release, in parallel with the live decoder's flush (its text is
        // only the fallback), so the key-release to text time is the longer of the two, not their sum.
        var pendingFinal: Task<String, Never>?

        await deps.lane.acquire()
        var laneHeld = true
        func releaseLane() { if laneHeld { laneHeld = false; deps.lane.release() } }
        defer { releaseLane() }

        do {
            let manager = try await deps.manager()
            await deps.prepare(manager)
            await manager.reset()
            await manager.setLanguage(nativeLanguageCode(options.language))
            let chunkSamples = await manager.config.chunkSamples
            let chunkFrames = max(1, chunkSamples / SegmentTracker.frameSamples)
            var tracker = SegmentTracker()
            var samplesIn = 0, consumed = 0
            var failed = false
            var lastPartial: (segment: Int, text: String, lang: String?) = (-1, "", nil)

            func frames() -> Int { samplesIn / chunkSamples * chunkFrames }

            /// Tokens the manager emitted since the last look (its timings leave out the lang tags).
            func newTokens(_ timings: [TokenTiming]) -> [LiveToken] {
                if timings.count < consumed { consumed = 0 }
                let fresh = timings[consumed...].compactMap { t -> LiveToken? in
                    // Latin-only: the Latin ship can't emit other scripts; this keeps the guarantee if the full ship is loaded.
                    SegmentTracker.hasNonLatin(t.token) ? nil
                        : LiveToken(frame: Int((t.startTime / ASRConstants.secondsPerEncoderFrame).rounded()), piece: t.token)
                }
                consumed = timings.count
                return fresh
            }

            func handle(_ outs: [SegmentOut]) {
                for o in outs {
                    switch o {
                    case .text(let segment, let text):
                        guard !text.isEmpty, !isCancelled,
                              lastPartial.segment != segment || lastPartial.text != text || lastPartial.lang != lang else { continue }
                        lastPartial = (segment, text, lang)
                        deps.emit(.partial(id, segment: segment, text: text, lang: lang))
                    case .cut(let segment, let text, let first, let last):
                        finals.append((segment, text, SegmentTracker.seconds(first), SegmentTracker.seconds(last.map { $0 + 1 })))
                    }
                }
                // Transcription finals go out at once; a dictation session holds its final for the finalizer.
                if !dictation, !isCancelled {
                    for f in finals { deps.emit(.final(id, segment: f.segment, text: f.text, lang: lang, start: f.start, end: f.end)) }
                    finals = []
                }
            }

            loop: for await command in commands {
                switch command {
                case .audio(let data, let queued):
                    if failed || isCancelled { continue }
                    let started = Date()
                    defer { LaneLog.record("live-\(id.channel)", .high, queued: queued, started: started, depth: 0) }
                    let samples = Self.floats(data)
                    if dictation { utterance += samples }
                    do {
                        _ = try await manager.process(samples: samples)
                        samplesIn += samples.count
                        let timings = await manager.getTokenTimings()
                        lang = await manager.detectedLanguage() ?? lang
                        handle(tracker.step(tokens: newTokens(timings), frames: frames()))
                    } catch {
                        failed = true
                        deps.emit(.error(.failed("live decoder: \(error)")))
                    }
                case .cut(let sample):
                    if dictation || failed || isCancelled { continue }  // a dictation utterance is one segment
                    tracker.addCut(sample: sample)
                    handle(tracker.step(tokens: [], frames: frames()))
                case .cancel:
                    await manager.reset()
                    return
                case .end:
                    if dictation, let finalize = deps.finalize, !utterance.isEmpty {
                        let code = options.language.split(separator: "-").first.map(String.init) ?? ""
                        let heard = utterance
                        pendingFinal = Task.detached(priority: .userInitiated) {
                            await finalize(heard, code.isEmpty || code == "auto" ? nil : code)
                        }
                    }
                    var tokens: [LiveToken] = []
                    if !failed {
                        do {
                            _ = try await manager.process(samples: [Float](repeating: 0, count: Int(Self.flushSeconds * 16000)))
                            let (_, timings) = try await manager.finishWithTokenTimings()
                            tokens = newTokens(timings)
                        } catch {
                            deps.emit(.error(.failed("live decoder: \(error)")))
                        }
                    }
                    lang = await manager.detectedLanguage() ?? lang
                    if isCancelled { await manager.reset(); return }
                    handle(tracker.end(tokens: tokens))
                    break loop
                }
            }
            await manager.reset()
        } catch {
            if !isCancelled { deps.emit(.error(error as? EngineError ?? .failed("\(error)"))) }
        }
        releaseLane()
        if isCancelled || !dictation { return }

        // Dictation: the whole utterance through the finalizer; the live text is the fallback.
        let live = finals.first
        var text = live?.text ?? ""
        if let pendingFinal {
            let better = await pendingFinal.value
            if !better.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = better }
        } else if let finalize = deps.finalize, !utterance.isEmpty {  // the stream ended without an .end command
            let code = options.language.split(separator: "-").first.map(String.init) ?? ""
            let better = await finalize(utterance, code.isEmpty || code == "auto" ? nil : code)
            if !better.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = better }
        }
        if !isCancelled {
            deps.emit(.final(id, segment: 0, text: text, lang: lang, start: live?.start, end: live?.end))
        }
    }

    static func floats(_ pcm: Data) -> [Float] {
        let n = pcm.count / 2
        return pcm.withUnsafeBytes { raw in
            (0..<n).map { i in
                let lo = UInt16(raw[2 * i]), hi = UInt16(raw[2 * i + 1])
                return Float(Int16(bitPattern: lo | hi << 8)) / 32768
            }
        }
    }
}

enum NativeLive {
    /// `--enginetest-live [--per N] [--mixed DIR] [--data DIR] [--cut-every SECONDS] [--vocab FILE]`
    /// Runs clips through NativeEngine (live decoder) and prints WER, language and segment checks.
    static func cli(_ args: [String]) -> Int32 {
        var done = false, code: Int32 = 0
        Task.detached {
            code = await LiveParity.run(args)
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        return code
    }
}

// MARK: --enginetest-live

private struct ParityClip { let id: String; let wav: URL; let ref: String; let lang: String }  // lang: "de", "en" or "" (auto)

private struct Seg { var text: String; var lang: String?; var start: Double?; var end: Double? }

/// What one engine said about one clip: finals by segment, the last partial, event kinds.
private struct Run { var finals: [Int: Seg] = [:]; var partials = 0; var firstPartialSegments = Set<Int>(); var errors = 0 }

enum LiveParity {
    private static func say(_ s: String) { print(s); fflush(stdout) }

    private static func words(_ s: String) -> [String] {
        s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .map(String.init).joined().split(separator: " ").map(String.init)
    }

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    private static func manifest(_ url: URL) -> [[String: Any]] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private static func readWav(_ url: URL) throws -> Data {
        let f = try AudioConverter().resampleAudioFile(url)
        return Data(f.flatMap { s -> [UInt8] in
            let v = Int16(max(-1, min(1, s)) * 32767)
            return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
        })
    }

    private static func localeFor(_ lang: String) -> String { lang == "de" ? "de-DE" : lang == "en" ? "en-US" : "" }

    // MARK: Engines

    private static func runNative(_ engine: NativeEngine, _ collector: Collector, pcm: Data, lang: String, cuts: [Int]) async -> Run {
        collector.reset()
        let id = engine.beginSession(SessionOptions(language: localeFor(lang), channel: .mic, kind: .transcription))
        let step = 3200
        var pending = cuts
        var i = 0
        while i < pcm.count {
            let end = min(pcm.count, i + step)
            engine.push(id, pcm: pcm.subdata(in: i..<end))
            while let c = pending.first, c * 2 <= end { engine.cut(id, at: c); pending.removeFirst() }
            i = end
        }
        engine.end(id)
        let want = cuts.count + 1
        let t0 = Date()
        while collector.finals() < want, Date().timeIntervalSince(t0) < 120 { try? await Task.sleep(nanoseconds: 20_000_000) }
        var run = Run()
        for e in collector.take() {
            switch e {
            case .partial(_, let seg, _, _): run.partials += 1; run.firstPartialSegments.insert(seg)
            case .final(_, let seg, let text, let lang, let s, let en): run.finals[seg] = Seg(text: text, lang: lang, start: s, end: en)
            case .error: run.errors += 1
            default: break
            }
        }
        return run
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [EngineEvent] = []
        func add(_ e: EngineEvent) { lock.lock(); events.append(e); lock.unlock() }
        func reset() { lock.lock(); events = []; lock.unlock() }
        func take() -> [EngineEvent] { lock.lock(); defer { lock.unlock() }; return events }
        func finals() -> Int { take().filter { if case .final = $0 { return true } else { return false } }.count }
    }

    // MARK: Report

    private struct Tally {
        var refWords = 0, errors = 0, clips = 0, leaks = 0, segments = 0
        mutating func add(ref: [String], hyp: [String], text: String) {
            refWords += ref.count; errors += editDistance(ref, hyp); clips += 1
            if SegmentTracker.hasNonLatin(text) { leaks += 1 }
        }
        var wer: Double { refWords == 0 ? 0 : 100 * Double(errors) / Double(refWords) }
    }

    static func run(_ args: [String]) async -> Int32 {
        func opt(_ k: String, _ d: String) -> String { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? d }
        let per = Int(opt("--per", "5")) ?? 5
        let cutEvery = Double(opt("--cut-every", "4")) ?? 4
        guard let dataPath = ModelHubCLI.benchDataDir(explicit: opt("--data", "")) else { return 2 }
        let dataDir = URL(fileURLWithPath: dataPath)
        let mixedDir = URL(fileURLWithPath: opt("--mixed", ""))

        var clips: [ParityClip] = []
        let man = manifest(dataDir.appendingPathComponent("manifest.jsonl"))
        for set in ["fleurs", "voxpopuli"] {
            for lang in ["de", "en"] {
                for d in man.filter({ $0["dataset"] as? String == set && $0["lang"] as? String == lang && ($0["kind"] as? String ?? "clip") == "clip" }).prefix(per) {
                    clips.append(ParityClip(id: d["id"] as! String, wav: dataDir.appendingPathComponent(d["wav"] as! String), ref: d["ref"] as? String ?? "", lang: lang))
                }
            }
        }
        var mixed: [ParityClip] = []
        for d in manifest(mixedDir.appendingPathComponent("manifest.jsonl")) {
            let refs = (d["parts"] as? [[String: Any]] ?? []).compactMap { $0["ref"] as? String }.joined(separator: " ")
            mixed.append(ParityClip(id: d["id"] as! String, wav: mixedDir.appendingPathComponent(d["wav"] as! String), ref: refs, lang: ""))
        }
        say("\(clips.count) clips + \(mixed.count) mixed; cuts every \(cutEvery) s in the second pass")

        let collector = Collector()
        let vocab = opt("--vocab", "")
        let engine = NativeEngine(finalizer: nil, vocabularyURL: vocab.isEmpty ? nil : URL(fileURLWithPath: vocab), useVocabulary: !vocab.isEmpty)
        engine.onEvent = { collector.add($0) }
        engine.start()
        let t0 = Date()
        while !engine.isReady, Date().timeIntervalSince(t0) < 120 { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard engine.isReady else { say("native engine never became ready (models missing?)"); return 2 }

        var native = Tally(), nativeMixed = Tally()
        var cutRuns = 0, wrongCount = 0, errors = 0
        var rows: [String] = []

        // One pass per clip without cuts (scored), one with cuts every `cutEvery` seconds (segment count only).
        func score(_ c: ParityClip, cuts: [Int], pcm: Data, into n: inout Tally) async {
            let nat = await runNative(engine, collector, pcm: pcm, lang: c.lang, cuts: cuts)
            errors += nat.errors
            let nText = (0...cuts.count).map { nat.finals[$0]?.text ?? "" }.joined(separator: " ")
            if cuts.isEmpty { n.add(ref: words(c.ref), hyp: words(nText), text: nText) } else { cutRuns += 1 }
            if nat.finals.count != cuts.count + 1 {
                wrongCount += 1
                rows.append("\(c.id): \(nat.finals.count) finals, wanted \(cuts.count + 1)")
            }
        }

        for (list, isMixed) in [(clips, false), (mixed, true)] {
            for c in list {
                guard let pcm = try? readWav(c.wav) else { say("cannot read \(c.wav.lastPathComponent)"); continue }
                var n = Tally()
                await score(c, cuts: [], pcm: pcm, into: &n)
                if isMixed { nativeMixed.refWords += n.refWords; nativeMixed.errors += n.errors; nativeMixed.clips += n.clips; nativeMixed.leaks += n.leaks
                } else { native.refWords += n.refWords; native.errors += n.errors; native.clips += n.clips; native.leaks += n.leaks }
                // Second pass: cuts every cutEvery seconds, away from the clip's last second
                let total = pcm.count / 2
                let cuts = stride(from: Int(cutEvery * 16000), to: total - 16000, by: Int(cutEvery * 16000)).map { $0 }
                if !isMixed, !cuts.isEmpty {
                    var dn = Tally()
                    await score(c, cuts: cuts, pcm: pcm, into: &dn)
                }
                say("\(c.id): done")
            }
        }


        // Dictation sessions: the finalizer's text replaces the live final; empty falls back to the live text.
        struct Fake: UtteranceFinalizer {
            let reply: String
            func finalize(pcm: [Float], lang: String?) async -> String { reply.isEmpty ? "" : "\(reply) \(pcm.count) \(lang ?? "auto")" }
        }
        if let c = clips.first, let pcm = try? readWav(c.wav) {
            for reply in ["FAKE", ""] {
                let de = NativeEngine(finalizer: Fake(reply: reply), vocabularyURL: nil, useVocabulary: false)
                let col = Collector()
                de.onEvent = { col.add($0) }
                let id = de.beginSession(SessionOptions(language: localeFor(c.lang), channel: .mic, kind: .dictation))
                de.push(id, pcm: pcm); de.cut(id, at: 16000); de.end(id)
                let t = Date()
                while col.finals() < 1, Date().timeIntervalSince(t) < 60 { try? await Task.sleep(nanoseconds: 20_000_000) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                let fin = col.take().compactMap { e -> String? in if case .final(_, let seg, let text, _, _, _) = e { return "seg \(seg): \(text)" } else { return nil } }
                say("dictation finalizer \(reply.isEmpty ? "empty (fallback)" : "set"): \(fin)")
            }
        }

        say("\n== Live decoder (WER is word error rate against the references, lowercased, punctuation dropped)")
        say(String(format: "FLEURS+VoxPopuli (%d clips): %.2f %%", native.clips, native.wer))
        say(String(format: "Mixed de/en (%d clips): %.2f %%", nativeMixed.clips, nativeMixed.wer))
        say("Non-Latin outputs: \(native.leaks + nativeMixed.leaks)")
        say("Cut runs: \(cutRuns) clips; wrong segment count \(wrongCount); engine errors \(errors)")
        for r in rows.prefix(40) { say(r) }
        return 0
    }
}
