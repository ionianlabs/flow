import FluidAudio
import Foundation

// Unit B (live). Streaming Nemotron: one LiveStream per session, behaviour-equal to the Session class in
// asr/server.py (live decoder only, like its ";live" start option): cuts at sample/1280 encoder frames,
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
    enum Command { case audio(Data), cut(Int), end, cancel }

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

    func push(_ pcm: Data) { if !isEnded { continuation.yield(.audio(pcm)) } }
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
                case .audio(let data):
                    if failed || isCancelled { continue }
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
    /// Fast checks without models, called from --selftest.
    static func selfTest() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            if !cond { FileHandle.standardError.write(Data("selftest FAIL (native live): \(name)\n".utf8)); ok = false }
        }
        func tok(_ f: Int, _ p: String) -> LiveToken { LiveToken(frame: f, piece: p) }
        typealias T = SegmentTracker

        // Pieces
        check("punct", T.isPunct(".") && T.isPunct("▁") && T.isPunct("…") && !T.isPunct("▁a") && !T.isPunct("7"))
        check("latin ok", !T.hasNonLatin("Grüße, naïve café œuvre ẞ ł"))
        check("latin cyrillic", T.hasNonLatin("привет"))
        check("latin devanagari", T.hasNonLatin("Hello हेलो"))
        check("latin greek", T.hasNonLatin("α"))
        check("latin digits and symbols ok", !T.hasNonLatin("100 € – „ja“"))
        check("decode", T.decode(pieces: ["▁Hel", "lo", "▁", "▁world", "."]) == "Hello world.")
        check("display seg0 keeps", T.display(". Hi", segment: 0) == ". Hi")
        check("display strips", T.display(".,? … Hi there", segment: 1) == "Hi there")
        check("display keeps inner", T.display("Hi. There", segment: 2) == "Hi. There")

        // Cut math: sample / 1280, at least previous + 1, at least 1
        var c = T()
        c.addCut(sample: 0); c.addCut(sample: 1279); c.addCut(sample: 12800); c.addCut(sample: 12801)
        check("cut math", c.cuts == [1, 2, 10, 11])
        check("seconds", T.seconds(5) == 0.4 && T.seconds(nil) == nil && T.seconds(13) == 1.04)

        // No cuts: one segment, text per change, final at the end
        var t = T()
        var o = t.step(tokens: [tok(0, "▁Hi")], frames: 7)
        check("step text", o == [.text(segment: 0, text: "Hi")])
        o = t.step(tokens: [], frames: 14)
        check("step no change", o.isEmpty)
        o = t.end(tokens: [tok(15, ".")])
        check("end", o == [.cut(segment: 0, text: "Hi.", first: 0, last: 0)])

        // Cut at frame 10: the next word moves on at once
        t = T()
        t.addCut(sample: 10 * 1280)
        o = t.step(tokens: [tok(1, "▁one"), tok(3, "▁two"), tok(11, "▁three")], frames: 14)
        check("cut at word", o == [.cut(segment: 0, text: "one two", first: 1, last: 3), .text(segment: 1, text: "three")])
        // The cut waits for the next word
        t = T()
        t.addCut(sample: 10 * 1280)
        _ = t.step(tokens: [tok(1, "▁one")], frames: 7)
        o = t.step(tokens: [tok(11, "▁three")], frames: 12)
        check("cut when word arrives", o.first == .cut(segment: 0, text: "one", first: 1, last: 1))

        // PUNCT_HOLD: a full stop after the cut still belongs to the previous segment; the hold ends the segment
        t = T()
        t.addCut(sample: 10 * 1280)
        _ = t.step(tokens: [tok(1, "▁one")], frames: 7)
        o = t.step(tokens: [], frames: 10 + T.punctHold - 1)
        check("hold waits", o.isEmpty)
        o = t.step(tokens: [tok(12, ".")], frames: 17)
        check("punct stays in segment 0", o == [.text(segment: 0, text: "one.")])
        o = t.step(tokens: [], frames: 10 + T.punctHold)
        check("hold ends", o == [.cut(segment: 0, text: "one.", first: 1, last: 1), .text(segment: 1, text: "")])

        // Punctuation that slips into the next segment is stripped there
        t = T()
        t.addCut(sample: 10 * 1280)
        _ = t.step(tokens: [tok(1, "▁one")], frames: 7)
        o = t.step(tokens: [tok(11, "▁and"), tok(12, "▁so")], frames: 14)
        check("next segment", o.contains(.text(segment: 1, text: "and so")))
        t = T()
        t.addCut(sample: 3 * 1280)
        o = t.step(tokens: [tok(1, "▁a"), tok(5, "."), tok(6, "▁b")], frames: 7)
        check("punct before next word goes with previous", o.first == .cut(segment: 0, text: "a.", first: 1, last: 1))
        t = T()
        t.addCut(sample: 3 * 1280)
        _ = t.step(tokens: [tok(1, "▁a")], frames: 7)
        _ = t.step(tokens: [tok(8, "▁b")], frames: 8)
        check("cut after decoder passed it", t.segment == 1)

        // End forces open cuts; an empty segment has no times
        t = T()
        t.addCut(sample: 5 * 1280)
        _ = t.step(tokens: [tok(1, "▁x")], frames: 3)
        o = t.end(tokens: [])
        check("end forces", o == [.cut(segment: 0, text: "x", first: 1, last: 1), .cut(segment: 1, text: "", first: nil, last: nil)])

        // Language codes, PCM
        check("lang", nativeLanguageCode("") == "auto" && nativeLanguageCode("de") == "de-DE" && nativeLanguageCode("en-GB") == "en-GB")
        check("pcm", LiveStream.floats(Data([0x00, 0x40, 0x00, 0xC0])) == [0.5, -0.5])
        return ok
    }

    /// `--enginetest-live [--socket PATH] [--per N] [--mixed DIR] [--data DIR] [--cut-every SECONDS] [--vocab FILE] [--no-python]`
    /// Runs clips through NativeEngine and the Python server (own socket, see LiveParity) and prints the parity numbers.
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

/// A minimal client of asr/server.py's socket protocol (frames: 1 byte type, 4 byte big-endian length, payload).
private final class PythonClient {
    struct Event { let type: String; let segment: Int; let text: String; let lang: String?; let start: Double?; let end: Double? }
    private let fd: Int32
    private let lock = NSLock()
    private(set) var events: [Event] = []
    private var buffer = Data()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { Darwin.close(fd); return nil }
        Thread.detachNewThread { [self] in readLoop() }
    }

    func send(_ kind: UInt8, _ payload: Data = Data()) {
        var f = Data([kind])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { f.append(contentsOf: $0) }
        f.append(payload)
        f.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = j["type"] as? String else { continue }
                let e = Event(type: type, segment: j["segment"] as? Int ?? 0, text: j["text"] as? String ?? (j["message"] as? String ?? ""),
                              lang: j["lang"] as? String, start: j["start"] as? Double, end: j["end"] as? Double)
                lock.lock(); events.append(e); lock.unlock()
            }
        }
    }

    func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
    func close() { Darwin.close(fd) }
}

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

    private static func runPython(_ path: String, pcm: Data, lang: String, cuts: [Int], live: Bool) async -> Run? {
        guard let c = PythonClient(path: path) else { return nil }
        defer { c.close() }
        let t0 = Date()
        while !c.snapshot().contains(where: { $0.type == "ready" }), Date().timeIntervalSince(t0) < 10 { try? await Task.sleep(nanoseconds: 20_000_000) }
        c.send(UInt8(ascii: "S"), Data((localeFor(lang) + (live ? ";live" : "")).utf8))
        var pending = cuts
        var i = 0
        while i < pcm.count {
            let end = min(pcm.count, i + 3200)
            c.send(UInt8(ascii: "A"), pcm.subdata(in: i..<end))
            while let k = pending.first, k * 2 <= end { c.send(UInt8(ascii: "K"), Data(String(k).utf8)); pending.removeFirst() }
            i = end
        }
        c.send(UInt8(ascii: "E"))
        let want = cuts.count + 1
        let t1 = Date()
        while c.snapshot().filter({ $0.type == "final" }).count < want, Date().timeIntervalSince(t1) < 120 { try? await Task.sleep(nanoseconds: 20_000_000) }
        var run = Run()
        for e in c.snapshot() {
            switch e.type {
            case "partial": run.partials += 1; run.firstPartialSegments.insert(e.segment)
            case "final": run.finals[e.segment] = Seg(text: e.text, lang: e.lang, start: e.start, end: e.end)
            case "error": run.errors += 1
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
        let socketPath = opt("--socket", "/tmp/ionian-ne-b.sock")
        let per = Int(opt("--per", "5")) ?? 5
        let cutEvery = Double(opt("--cut-every", "4")) ?? 4
        let usePython = !args.contains("--no-python") && FileManager.default.fileExists(atPath: socketPath)
        let dataDir = URL(fileURLWithPath: opt("--data", ProcessInfo.processInfo.environment["FLOW_BENCH"].map { $0 + "/data" } ?? ""))
        let mixedDir = URL(fileURLWithPath: opt("--mixed", ""))
        if !usePython { say("(no Python server on \(socketPath): native only)") }

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

        var native = Tally(), pyLive = Tally(), nativeMixed = Tally(), pyMixed = Tally()
        var agree = 0, compared = 0, durationDiffs: [Double] = [], startDiffs: [Double] = [], countEqual = 0, cutRuns = 0
        var boundaryDiffs: [Int] = [], langDiffs = 0, partialsMissing = 0, errors = 0
        var rows: [String] = []

        func score(_ c: ParityClip, cuts: [Int], pcm: Data, into n: inout Tally, py l: inout Tally, cutPass: Bool) async {
            let nat = await runNative(engine, collector, pcm: pcm, lang: c.lang, cuts: cuts)
            errors += nat.errors
            let nText = (0...cuts.count).map { nat.finals[$0]?.text ?? "" }.joined(separator: " ")
            let ref = words(c.ref)
            if !cutPass { n.add(ref: ref, hyp: words(nText), text: nText) }
            if nat.finals.count != cuts.count + 1 { rows.append("\(c.id) native: \(nat.finals.count) finals, wanted \(cuts.count + 1)") }
            guard usePython, let py = await runPython(socketPath, pcm: pcm, lang: c.lang, cuts: cuts, live: true) else { return }
            let pText = (0...cuts.count).map { py.finals[$0]?.text ?? "" }.joined(separator: " ")
            if !cutPass {
                l.add(ref: ref, hyp: words(pText), text: pText)
                compared += 1
                if words(nText) == words(pText) { agree += 1 }
            } else {
                cutRuns += 1
                if nat.finals.count == py.finals.count { countEqual += 1 }
                // Word offset of each boundary, native vs Python
                var a = 0, b = 0
                for k in 0..<cuts.count {
                    a += words(nat.finals[k]?.text ?? "").count; b += words(py.finals[k]?.text ?? "").count
                    boundaryDiffs.append(abs(a - b))
                }
            }
            for (k, ns) in nat.finals {
                guard let ps = py.finals[k] else { continue }
                if let s1 = ns.start, let s2 = ps.start { startDiffs.append(abs(s1 - s2)) }
                if let e1 = ns.end, let e2 = ps.end { durationDiffs.append(abs(e1 - e2)) }
                if ns.lang != ps.lang, !ns.text.isEmpty { langDiffs += 1 }
            }
            if nat.partials == 0, py.partials > 0 { partialsMissing += 1 }
            if !cutPass, words(nText) != words(pText) {
                rows.append("\(c.id)\n   native: \(nText)\n   python: \(pText)")
            }
        }

        for (list, isMixed) in [(clips, false), (mixed, true)] {
            for c in list {
                guard let pcm = try? readWav(c.wav) else { say("cannot read \(c.wav.lastPathComponent)"); continue }
                var n = Tally(), l = Tally()
                await score(c, cuts: [], pcm: pcm, into: &n, py: &l, cutPass: false)
                if isMixed { nativeMixed.refWords += n.refWords; nativeMixed.errors += n.errors; nativeMixed.clips += n.clips; nativeMixed.leaks += n.leaks
                    pyMixed.refWords += l.refWords; pyMixed.errors += l.errors; pyMixed.clips += l.clips; pyMixed.leaks += l.leaks
                } else {
                    native.refWords += n.refWords; native.errors += n.errors; native.clips += n.clips; native.leaks += n.leaks
                    pyLive.refWords += l.refWords; pyLive.errors += l.errors; pyLive.clips += l.clips; pyLive.leaks += l.leaks
                }
                // Second pass: cuts every cutEvery seconds, away from the clip's last second
                let total = pcm.count / 2
                let cuts = stride(from: Int(cutEvery * 16000), to: total - 16000, by: Int(cutEvery * 16000)).map { $0 }
                if !isMixed, !cuts.isEmpty {
                    var dn = Tally(), dl = Tally()
                    await score(c, cuts: cuts, pcm: pcm, into: &dn, py: &dl, cutPass: true)
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

        say("\n== Parity (WER is word error rate against the references, lowercased, punctuation dropped)")
        say(String(format: "FLEURS+VoxPopuli (%d clips): native %.2f %%   python live %@", native.clips, native.wer, usePython ? String(format: "%.2f %%", pyLive.wer) : "n/a"))
        say(String(format: "Mixed de/en (%d clips): native %.2f %%   python live %@", nativeMixed.clips, nativeMixed.wer, usePython ? String(format: "%.2f %%", pyMixed.wer) : "n/a"))
        say("Identical word sequence to Python live: \(agree) of \(compared) clips")
        say("Non-Latin outputs: native \(native.leaks + nativeMixed.leaks), python \(pyLive.leaks + pyMixed.leaks)")
        say("Cut runs: \(cutRuns) clips; equal segment count \(countEqual); boundary word-offset diff max \(boundaryDiffs.max() ?? 0), mean \(String(format: "%.2f", Double(boundaryDiffs.reduce(0, +)) / Double(max(1, boundaryDiffs.count))))")
        func stat(_ v: [Double]) -> String {
            let s = v.sorted(); guard !s.isEmpty else { return "n/a" }
            return String(format: "n=%d median %.2f p90 %.2f max %.2f s, %.0f %% within 0.1 s", s.count, s[s.count / 2], s[Int(Double(s.count - 1) * 0.9)], s.last!, 100 * Double(s.filter { $0 <= 0.1 }.count) / Double(s.count))
        }
        say("Final start diff: \(stat(startDiffs))")
        say("Final end diff:   \(stat(durationDiffs))")
        say("Language tag differs on \(langDiffs) segments; clips with no native partial but Python partials: \(partialsMissing); native errors: \(errors)")
        for r in rows.prefix(40) { say(r) }
        return 0
    }
}
