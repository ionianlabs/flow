import FluidAudio
import Foundation

// Unit C (dictation final). Whole-utterance final for dictation: Parakeet Ultra re-reads the buffered utterance,
// CTC vocabulary rescoring (library defaults, "ctc-default" as measured in Phase 0), the common-word guard
// (zipf 4.0, port of the former Python pk_post.py guard()), then VocabNormalizer. Models come from ModelHub.parakeet();
// FinalPass (transcription mode) shares the same instance.

protocol UtteranceFinalizer: Sendable {
    /// pcm: 16 kHz mono Float. lang: "de"/"en"/nil (auto; Parakeet detects it itself).
    /// Returns "" when the final pass failed or heard nothing; the caller then keeps the live text.
    func finalize(pcm: [Float], lang: String?) async -> String
}

/// The production finalizer. Runs its model work through `hub.serial`.
final class ParakeetFinalizer: UtteranceFinalizer, @unchecked Sendable {
    private let hub: ModelHub
    private let vocabularyURL: URL
    private let frequency: WordFrequency
    private let lock = NSLock()
    private var stale = true
    private var builtFrom: Date?
    private var terms: [String] = []
    private var session: VocabularyBoostingSession?
    private var normalizer: VocabNormalizer?

    init(hub: ModelHub = .shared, vocabularyURL: URL = Settings.vocabularyFile,
         frequency: WordFrequency = WordFrequencyTable.shared) {
        self.hub = hub
        self.vocabularyURL = vocabularyURL
        self.frequency = frequency
    }

    /// Rebuild the CTC vocabulary session after the vocabulary file changed (lazy: at the next finalize).
    func reloadVocabulary() {
        lock.withLock { stale = true }
    }

    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: vocabularyURL.path))?[.modificationDate] as? Date
    }

    func finalize(pcm: [Float], lang: String?) async -> String {
        guard !pcm.isEmpty else { return "" }
        var samples = pcm
        if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }  // Parakeet wants >= 1 s
        do {
            return try await hub.serial(label: "dictation") { try await self.run(samples) }
        } catch {
            NSLog("Ionian Flow: dictation final failed: %@", error.localizedDescription)
            return ""
        }
    }

    /// Inside `hub.serial`.
    private func run(_ samples: [Float]) async throws -> String {
        let models = try await hub.parakeet()
        try await refreshVocabulary(models.ctc)
        var state = TdtDecoderState.make()
        let result = try await models.asr.transcribe(samples, decoderState: &state)
        var text = result.text
        let (session, normalizer) = current()
        if let session, let timings = result.tokenTimings,
           let out = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples), out.wasModified {
            text = DictationFinal.guardReplacements(original: result.text, rescored: out.text, frequency: frequency)
        }
        return normalizer?.normalize(text) ?? text
    }

    private func refreshVocabulary(_ ctc: CtcModels) async throws {
        let mtime = modified()
        guard needsRebuild(mtime) else { return }
        let markdown = (try? String(contentsOf: vocabularyURL, encoding: .utf8)) ?? ""
        let parsed = VocabularyParser.parse(markdown)
        var newSession: VocabularyBoostingSession?
        var seen = Set<String>(), list: [String] = []
        for t in parsed.terms where seen.insert(t.text).inserted { list.append(t.text) }
        if !list.isEmpty {
            let context = CustomVocabularyContext(terms: list.map { CustomVocabularyTerm(text: $0) })
            newSession = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc, thresholds: .init())
        }
        let norm = parsed.terms.isEmpty ? nil : VocabNormalizer(parsed, frequency: frequency)
        store(newSession, norm, list, mtime)
    }

    private func needsRebuild(_ mtime: Date?) -> Bool {
        lock.withLock { stale || mtime != builtFrom }
    }

    private func store(_ s: VocabularyBoostingSession?, _ n: VocabNormalizer?, _ list: [String], _ mtime: Date?) {
        lock.withLock { session = s; normalizer = n; terms = list; builtFrom = mtime; stale = false }
    }

    private func current() -> (VocabularyBoostingSession?, VocabNormalizer?) {
        lock.withLock { (session, normalizer) }
    }
}

enum DictationFinal {
    /// Port of guard() in the former Python pk_post.py: word-diff the plain text against the CTC-rescored one and revert a change
    /// whose original words are all common (ordinary German or English at `zipf`). Inserts are kept. The diff is
    /// used rather than RescoreOutput.replacements because that list has no word positions, so a multi-word span
    /// can't be mapped back exactly; the diff is also what the Phase 0 numbers were measured with.
    static func guardReplacements(original: String, rescored: String, frequency: WordFrequency, zipf: Double = 4.0) -> String {
        let a = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = rescored.split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [String] = []
        for op in diff(a, b) {
            if op.equal || op.a.isEmpty { out += b[op.b]; continue }
            let orig = Array(a[op.a])
            let revert = orig.allSatisfy { w in
                let stripped = stripNonWord(w)
                return stripped.isEmpty || frequency.common(stripped, zipf: zipf)
            }
            out += revert ? orig : Array(b[op.b])
        }
        return out.joined(separator: " ")
    }

    private static func stripNonWord(_ w: String) -> String {
        String(String.UnicodeScalarView(w.unicodeScalars.filter {
            $0 == "_" || $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }

    struct Op { let equal: Bool; let a: Range<Int>; let b: Range<Int> }

    /// Opcodes like difflib's (equal runs, and runs between them as one replace/delete/insert), from an LCS.
    static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                let (si, sj) = (i, j)
                while i < n, j < m, a[i] == b[j] { i += 1; j += 1 }
                ops.append(Op(equal: true, a: si..<i, b: sj..<j))
            } else {
                let (si, sj) = (i, j)
                while i < n || j < m, !(i < n && j < m && a[i] == b[j]) {
                    if i < n, j < m { if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 } else { j += 1 } }
                    else if i < n { i += 1 } else { j += 1 }
                }
                ops.append(Op(equal: false, a: si..<i, b: sj..<j))
            }
        }
        return ops
    }
}

// MARK: test CLI

extension DictationFinal {
    private struct Clip: Decodable { let id: String; let wav: String; let lang: String?; let dataset: String? }
    private struct VocabHyp: Encodable { let id: String; let text: String }
    private struct DictHyp: Encodable { let id: String; let raw: String; let text: String; let lang: String; let ms: Int }

    private static func clips(_ url: URL) throws -> [Clip] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
    }

    private static let usage = """
    --enginetest-dictation vocab DIR                         72 vocab clips (DIR/manifest.jsonl, DIR/Vocabulary.md) -> DIR/hyp-app-dictation.jsonl
    --enginetest-dictation dict MANIFEST VOCAB.md OUTDIR [datasets]   800 clips -> OUTDIR/hyp-app-dictation-final.jsonl
    --enginetest-dictation latency MANIFEST VOCAB.md [trials]         end of audio to text at 3 s and 10 s

    """

    /// `--enginetest-dictation ...`. Return the process exit code.
    static func cli(_ args: [String]) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var rc: Int32 = 0
        Task.detached {
            do { rc = try await runCLI(args) } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); rc = 1 }
            done.signal()
        }
        done.wait()
        return rc
    }

    private static func runCLI(_ a: [String]) async throws -> Int32 {
        guard let mode = a.first else { FileHandle.standardError.write(Data(usage.utf8)); return 2 }
        let enc = JSONEncoder(); enc.outputFormatting = .withoutEscapingSlashes
        let nl = Data("\n".utf8)
        let conv = AudioConverter()
        func finalizer(_ vocab: String) -> ParakeetFinalizer { ParakeetFinalizer(vocabularyURL: URL(fileURLWithPath: vocab)) }
        switch mode {
        case "vocab" where a.count >= 2:
            let dir = URL(fileURLWithPath: a[1])
            let f = finalizer(dir.appendingPathComponent("Vocabulary.md").path)
            var data = Data()
            for c in try clips(dir.appendingPathComponent("manifest.jsonl")) {
                let x = try conv.resampleAudioFile(dir.appendingPathComponent(c.wav))
                let t = await f.finalize(pcm: x, lang: c.lang)
                data += try enc.encode(VocabHyp(id: c.id, text: t)) + nl
                print(c.id, "|", t.prefix(70))
            }
            try data.write(to: dir.appendingPathComponent("hyp-app-dictation.jsonl"))
        case "dict" where a.count >= 4:
            let manifest = URL(fileURLWithPath: a[1]), out = URL(fileURLWithPath: a[3])
            let sets = a.count > 4 ? Set(a[4].split(separator: ",").map(String.init)) : ["fleurs", "voxpopuli"]
            let list = try clips(manifest).filter { sets.contains($0.dataset ?? "") && $0.lang != nil }
            let f = finalizer(a[2])
            // Raw (no rescoring, no spelling pass) comes from a second finalizer without a vocabulary file.
            let plain = finalizer("/nonexistent/Vocabulary.md")
            let base = manifest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var data = Data()
            for (i, c) in list.enumerated() {
                let x = try conv.resampleAudioFile(base.appendingPathComponent(c.wav))
                let raw = await plain.finalize(pcm: x, lang: c.lang)
                let t = Date()
                let text = await f.finalize(pcm: x, lang: c.lang)
                let ms = Int(Date().timeIntervalSince(t) * 1000)
                data += try enc.encode(DictHyp(id: c.id, raw: raw, text: text, lang: c.lang ?? "", ms: ms)) + nl
                if i % 50 == 0 { print(i, "/", list.count) }
            }
            try data.write(to: out.appendingPathComponent("hyp-app-dictation-final.jsonl"))
        case "latency" where a.count >= 3:
            let manifest = URL(fileURLWithPath: a[1])
            let trials = a.count > 3 ? Int(a[3]) ?? 8 : 8
            let pool = try clips(manifest).filter { $0.dataset == "fleurs" && $0.lang == "en" }
            let f = finalizer(a[2])
            let base = manifest.deletingLastPathComponent()
            var cursor = 0
            func q(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            print("len_s  median_ms (end of audio to text, provisional)")
            for len in [3, 10] {
                var ms: [Double] = []
                for trial in 0...trials {  // trial 0 warms up
                    var x: [Float] = []
                    while x.count < len * 16_000 {
                        x += try conv.resampleAudioFile(base.appendingPathComponent(pool[cursor % pool.count].wav)); cursor += 1
                        x += [Float](repeating: 0, count: 4_800)
                    }
                    x = Array(x.prefix(len * 16_000))
                    let t = Date()
                    _ = await f.finalize(pcm: x, lang: nil)
                    if trial > 0 { ms.append(Date().timeIntervalSince(t) * 1000) }
                }
                print(String(format: "%4d   %8.0f", len, q(ms)))
            }
        default:
            FileHandle.standardError.write(Data(usage.utf8)); return 2
        }
        return 0
    }
}
