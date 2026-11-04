// Parakeet TDT Ultra + FluidAudio CTC vocabulary rescoring (VocabularyBoostingSession, parakeet-ctc-110m).
import FluidAudio
import Foundation

struct Setting { let label: String; let thresholds: VocabularyBoostingSession.Thresholds? }
// nil = rescoring off. "default" = library defaults (favours recall); "dict" = the library's dictation advice
// (a wrong replacement costs more than a miss); "strict" = even fewer replacements.
let ctcSettings: [Setting] = [
    Setting(label: "ctc-off", thresholds: nil),
    Setting(label: "ctc-default", thresholds: .init()),
    Setting(label: "ctc-dict", thresholds: .init(cbw: 0, minSimilarity: 0.7)),
    Setting(label: "ctc-strict", thresholds: .init(cbw: -2, minSimilarity: 0.8)),
]

struct MClip: Decodable { let id: String; let wav: String; let lang: String?; let dataset: String?; let seconds: Double? }
struct VocabHyp: Codable { let id: String; let text: String }
struct DictHyp: Codable { let id: String; let raw: String; let text: String; let lang: String; let ms: Int }

func readManifest(_ url: URL) throws -> [MClip] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(MClip.self, from: Data($0.utf8)) }
}

/// Terms are the bullets under "## Terms" (same file the Python bench reads).
func readTerms(_ url: URL) throws -> [String] {
    var inTerms = false
    var terms: [String] = []
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("## ") { inTerms = l.lowercased() == "## terms"; continue }
        if inTerms, l.hasPrefix("- ") || l.hasPrefix("* ") { terms.append(String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
    }
    return terms
}

func peakRSSMB() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576  // bytes on macOS
}

struct Engine {
    let asr: AsrManager
    let session: [String: VocabularyBoostingSession]  // by setting label

    func decode(_ samples: [Float]) async throws -> ASRResult {
        var st = TdtDecoderState.make()
        return try await asr.transcribe(samples, decoderState: &st)
    }
    func rescore(_ r: ASRResult, _ samples: [Float], label: String) async -> String {
        guard let s = session[label], let t = r.tokenTimings,
              let out = await s.rescore(text: r.text, tokenTimings: t, audioSamples: samples) else { return r.text }
        return out.text
    }
}

@MainActor func loadEngine(terms: [String], settings: [Setting]) async throws -> Engine {
    let t0 = Date()
    let models = try await AsrModels.downloadAndLoad(version: .ultra)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    var warm = TdtDecoderState.make()
    _ = try await asr.transcribe([Float](repeating: 0, count: 16000), decoderState: &warm)
    print(String(format: "loaded Ultra in %.1f s, peak RSS %.0f MB", Date().timeIntervalSince(t0), peakRSSMB()))
    let t1 = Date()
    let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    let vocab = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
    var sessions: [String: VocabularyBoostingSession] = [:]
    for s in settings { if let th = s.thresholds {
        sessions[s.label] = try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc, thresholds: th)
    } }
    print(String(format: "loaded CTC + %d terms in %.1f s, peak RSS %.0f MB", terms.count, Date().timeIntervalSince(t1), peakRSSMB()))
    return Engine(asr: asr, session: sessions)
}

@MainActor func runCtcMode(_ a: [String]) async throws {
    let enc = JSONEncoder(); enc.outputFormatting = .withoutEscapingSlashes
    let conv = AudioConverter()
    let nl = Data("\n".utf8)
    switch a[1] {
    case "vocab":
        let dir = URL(fileURLWithPath: a[2])
        let clips = try readManifest(dir.appendingPathComponent("manifest.jsonl"))
        let terms = try readTerms(dir.appendingPathComponent("Vocabulary.md"))
        let eng = try await loadEngine(terms: terms, settings: ctcSettings)
        var outs: [String: [Data]] = [:]
        for c in clips {
            let x = try conv.resampleAudioFile(dir.appendingPathComponent(c.wav))
            let r = try await eng.decode(x)
            for s in ctcSettings {
                let t = s.thresholds == nil ? r.text : await eng.rescore(r, x, label: s.label)
                outs[s.label, default: []].append(try enc.encode(VocabHyp(id: c.id, text: t)))
            }
            print(c.id, "|", r.text.prefix(70))
        }
        for s in ctcSettings {
            let url = dir.appendingPathComponent("hyp-parakeet-\(s.label).jsonl")
            try (outs[s.label] ?? []).reduce(Data()) { $0 + $1 + nl }.write(to: url)
        }
    case "dict":
        guard a.count >= 5 else { print("dict MANIFEST OUT VOCAB.md [datasets]"); exit(2) }
        let mURL = URL(fileURLWithPath: a[2]); let out = URL(fileURLWithPath: a[3])
        let sets = a.count > 5 ? Set(a[5].split(separator: ",").map(String.init)) : ["fleurs", "voxpopuli"]
        let clips = try readManifest(mURL).filter { sets.contains($0.dataset ?? "") && $0.lang != nil }
        // CTC_SETTING=ctc-default|ctc-dict|ctc-strict picks the thresholds (default ctc-dict)
        let setting = ctcSettings.first { $0.label == ProcessInfo.processInfo.environment["CTC_SETTING"] } ?? ctcSettings[2]
        let eng = try await loadEngine(terms: try readTerms(URL(fileURLWithPath: a[4])), settings: [setting])
        let base = mURL.deletingLastPathComponent()
        var data = Data()
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (i, c) in clips.enumerated() {
            let x = try conv.resampleAudioFile(base.appendingPathComponent(c.wav))
            let t = Date()
            let r = try await eng.decode(x)
            let text = await eng.rescore(r, x, label: setting.label)
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            data += try enc.encode(DictHyp(id: c.id, raw: r.text, text: text, lang: c.lang ?? "", ms: ms)) + nl
            if i % 50 == 0 { print(i, "/", clips.count) }
        }
        try data.write(to: out)
    case "latency":
        // Key release to text: Parakeet (+ CTC) over the whole buffered utterance, for 3/10/30/60 s dictations
        // built by concatenating FLEURS clips with 0.3 s gaps. Trials are distinct windows; one warm-up each.
        let mURL = URL(fileURLWithPath: a[2])
        let trials = a.count > 4 ? Int(a[4]) ?? 8 : 8
        let pool = try readManifest(mURL).filter { $0.dataset == "fleurs" && $0.lang == "en" }
        let eng = try await loadEngine(terms: try readTerms(URL(fileURLWithPath: a[3])), settings: [ctcSettings[2]])
        let base = mURL.deletingLastPathComponent()
        var cache: [String: [Float]] = [:]
        func clip(_ c: MClip) throws -> [Float] {
            if let v = cache[c.id] { return v }
            let v = try conv.resampleAudioFile(base.appendingPathComponent(c.wav)); cache[c.id] = v; return v
        }
        func q(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
        var cursor = 0
        print("len_s  asr_median asr_p90 | +ctc_median +ctc_p90 | (ms, end of audio to text)")
        for len in [3, 10, 30, 60] {
            var asrMs: [Double] = [], totMs: [Double] = []
            for trial in 0...trials {  // trial 0 = warm-up
                var x: [Float] = []
                while x.count < len * 16000 {
                    x += try clip(pool[cursor % pool.count]); cursor += 1
                    x += [Float](repeating: 0, count: 4800)
                }
                x = Array(x.prefix(len * 16000))
                let t = Date()
                let r = try await eng.decode(x)
                let t1 = Date()
                _ = await eng.rescore(r, x, label: "ctc-dict")
                let t2 = Date()
                if trial > 0 { asrMs.append(t1.timeIntervalSince(t) * 1000); totMs.append(t2.timeIntervalSince(t) * 1000) }
            }
            print(String(format: "%4d   %8.0f %7.0f | %9.0f %8.0f", len, q(asrMs, 0.5), q(asrMs, 0.9), q(totMs, 0.5), q(totMs, 0.9)))
        }
        print(String(format: "peak RSS %.0f MB", peakRSSMB()))
    default: break
    }
}
