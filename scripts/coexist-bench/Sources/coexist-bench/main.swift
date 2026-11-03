// coexist-bench: the Phase 0 coexistence test. ONE process holds
//   - two Nemotron streaming managers ("You" and "Them", 1120 ms, Latin ship),
//   - Parakeet TDT Ultra + the CTC vocabulary model (final pass at each clip end),
//   - Gemma 4 E2B through mlx-swift-lm (one polish call per final).
// Both streams are fed in real time with different manifest clips, like a meeting. All Parakeet and Gemma
// work goes through ONE actor (Serial). Once a minute a line goes to the log: memory, counts, latencies, errors.
//
//   coexist-bench --vocab TERMS.md [--minutes 30] [--log FILE] [--data DIR] [--llm DIR]
// --data defaults to the bench harness checkout next to this repo (FLOW_BENCH overrides), --llm to the
// cached Hugging Face snapshot of mlx-community/gemma-4-e2b-it-4bit.
import FluidAudio
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: arguments and paths

var opts: [String: String] = [:]
do {
    let raw = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < raw.count {
        if raw[i].hasPrefix("--"), i + 1 < raw.count { opts[String(raw[i].dropFirst(2))] = raw[i + 1]; i += 2 } else { i += 1 }
    }
}
guard let vocabPath = opts["vocab"] else {
    FileHandle.standardError.write(Data("usage: coexist-bench --vocab TERMS.md [--minutes 30] [--log FILE] [--data DIR] [--llm DIR]\n".utf8))
    exit(2)
}
let minutes = Double(opts["minutes"] ?? "30") ?? 30
let logURL = URL(fileURLWithPath: opts["log"] ?? "coexist.log")
let env = ProcessInfo.processInfo.environment
let dataDir = URL(fileURLWithPath: opts["data"] ?? ((env["FLOW_BENCH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("flow-bench/bench").path) + "/data"))
let llmDir: URL = {
    if let p = opts["llm"] { return URL(fileURLWithPath: p) }
    let snaps = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots")
    let first = (try? FileManager.default.contentsOfDirectory(atPath: snaps.path))?.sorted().first ?? "missing"
    return snaps.appendingPathComponent(first)
}()

// MARK: log

let startTime = Date()
let logLock = NSLock()
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try FileHandle(forWritingTo: logURL)
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    let line = String(format: "[%7.1fs] ", Date().timeIntervalSince(startTime)) + s
    print(line)
    logHandle.write(Data((line + "\n").utf8))
}

// MARK: memory

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

// MARK: per-minute metrics

final class Metrics: @unchecked Sendable {
    private let lock = NSLock()
    var partials = 0, finals = 0, parakeetDone = 0, polishDone = 0
    var parakeetMs: [Double] = [], polishMs: [Double] = [], processMs: [Double] = []
    var errors: [String] = []
    var allErrors: [String] = []
    var queued = 0  // clips waiting for or inside the serial executor
    func add(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }
    /// Snapshot and reset the per-minute windows (counts are cumulative).
    func drain() -> (pk: [Double], pol: [Double], proc: [Double], errs: [String]) {
        lock.lock(); defer { lock.unlock() }
        let r = (parakeetMs, polishMs, processMs, errors)
        parakeetMs = []; polishMs = []; processMs = []; errors = []
        return r
    }
    func error(_ s: String) { add { errors.append(s); allErrors.append(s) }; log("ERROR \(s)") }
}
let metrics = Metrics()

func pct(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}

// MARK: manifest

struct Clip: Decodable { let id: String; let dataset: String?; let lang: String; let wav: String; let seconds: Double? }
func locale(_ lang: String) -> String { lang == "de" ? "de-DE" : lang == "en" ? "en-US" : lang }

let manifestText = try String(contentsOf: dataDir.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
var allClips: [Clip] = []
for line in manifestText.split(separator: "\n") {
    let c = try JSONDecoder().decode(Clip.self, from: Data(line.utf8))
    let secs = c.seconds ?? 0
    if c.dataset == "fleurs", c.lang == "de" || c.lang == "en", secs >= 5, secs <= 30 { allClips.append(c) }
}
precondition(allClips.count >= 20, "need FLEURS clips under \(dataDir.path)")
let converter = AudioConverter()

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

// MARK: the serial executor: Parakeet + CTC and Gemma, one job at a time

let polishSystem = """
You clean up one segment of a live meeting transcript produced by speech recognition. Fix punctuation and \
capitalisation, remove filler words and obvious repetitions, keep the language of the segment and every \
fact. Output only the cleaned segment on one line.
"""

actor Serial {
    let asr: AsrManager
    let rescorer: VocabularyBoostingSession
    let llm: ModelContainer

    init(asr: AsrManager, rescorer: VocabularyBoostingSession, llm: ModelContainer) {
        self.asr = asr; self.rescorer = rescorer; self.llm = llm
    }

    /// Parakeet Ultra over the whole clip, then CTC rescoring. Returns text and total ms.
    func final(_ samples: [Float]) async throws -> (String, Double) {
        let t = Date()
        var st = TdtDecoderState.make()
        let r = try await asr.transcribe(samples, decoderState: &st)
        var text = r.text
        if let timings = r.tokenTimings,
           let out = await rescorer.rescore(text: r.text, tokenTimings: timings, audioSamples: samples) {
            text = out.text
        }
        return (text, Date().timeIntervalSince(t) * 1000)
    }

    /// One Gemma polish call (greedy, thinking off, n-1 prefill rule from Polisher).
    func polish(_ text: String) async throws -> (String, Double) {
        let t = Date()
        let input = try await llm.prepare(input: UserInput(
            chat: [.system(polishSystem), .user("Segment: \(text)\nOutput:")],
            additionalContext: ["enable_thinking": false]))
        var params = GenerateParameters(maxTokens: 160, temperature: 0)
        // Prefill all but the last prompt token without logits (otherwise ~2x slower prefill).
        params.prefill.stepSize = max(1, input.text.tokens.size - 1)
        let stream = try await llm.generate(input: input, parameters: params)
        var out = ""
        for await g in stream {
            if let c = g.chunk {
                out += c
                if out.drop(while: { $0.isWhitespace || $0.isNewline }).contains("\n") { break }
            }
        }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(t) * 1000)
    }
}

// MARK: load everything

func loadNemotron(_ name: String) async throws -> StreamingNemotronMultilingualAsrManager {
    let t = Date()
    let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(languageCode: "de", chunkMs: 1120)
    let m = StreamingNemotronMultilingualAsrManager()
    try await m.loadModels(from: dir)
    _ = try await m.process(samples: [Float](repeating: 0, count: 16000))
    _ = try await m.finish()
    await m.reset()
    log(String(format: "loaded Nemotron %@ in %.1f s, footprint %.0f MB", name, Date().timeIntervalSince(t), physFootprintMB()))
    return m
}

log("coexist-bench: \(minutes) min, data \(dataDir.lastPathComponent), \(allClips.count) clips, llm \(llmDir.lastPathComponent.prefix(8))")
let you = try await loadNemotron("You")
let them = try await loadNemotron("Them")

var t = Date()
let parakeetModels = try await AsrModels.downloadAndLoad(version: .ultra)
let parakeet = AsrManager(config: .default)
try await parakeet.loadModels(parakeetModels)
var warm = TdtDecoderState.make()
_ = try await parakeet.transcribe([Float](repeating: 0, count: 16000), decoderState: &warm)
log(String(format: "loaded Parakeet Ultra in %.1f s, footprint %.0f MB", Date().timeIntervalSince(t), physFootprintMB()))

t = Date()
let terms = try readTerms(URL(fileURLWithPath: vocabPath))
let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
let rescorer = try await VocabularyBoostingSession(
    vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }),
    ctcModels: ctc, thresholds: .init(cbw: 0, minSimilarity: 0.7))
log(String(format: "loaded CTC with %d terms in %.1f s, footprint %.0f MB", terms.count, Date().timeIntervalSince(t), physFootprintMB()))

t = Date()
let container = try await LLMModelFactory.shared.loadContainer(from: llmDir, using: #huggingFaceTokenizerLoader())
let serial = Serial(asr: parakeet, rescorer: rescorer, llm: container)
let (warmText, _) = try await serial.polish("so um the build is uh twenty percent faster now")
log(String(format: "loaded Gemma in %.1f s, footprint %.0f MB, warm-up polish: %@", Date().timeIntervalSince(t), physFootprintMB(), warmText))

// MARK: the two live streams

let deadline = Date().addingTimeInterval(minutes * 60)
let feedingDone = Date().addingTimeInterval(minutes * 60)

/// Runs "You" or "Them" until the deadline: a clip, a 0.5 to 1.5 s pause, the next clip. At each clip end the
/// Nemotron final is taken, then Parakeet + CTC and the polish are queued on the serial executor without
/// waiting for them (the next speech keeps coming, as in a meeting).
func runStream(_ name: String, _ manager: StreamingNemotronMultilingualAsrManager, offset: Int, stride: Int) async {
    let step = 1600  // 100 ms, like the app's audio tap
    var index = offset
    var pending: [Task<Void, Never>] = []
    while Date() < deadline {
        let clip = allClips[index % allClips.count]
        index += stride
        let samples: [Float]
        do { samples = try converter.resampleAudioFile(dataDir.appendingPathComponent(clip.wav)) } catch {
            metrics.error("\(name) read \(clip.id): \(error)"); continue
        }
        await manager.setLanguage(locale(clip.lang))
        let t0 = DispatchTime.now().uptimeNanoseconds
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 }
        var k = 0
        var lastPartial = ""
        while k * step < samples.count, Date() < deadline {
            let end = min(samples.count, (k + 1) * step)
            let wait = Double(k + 1) * 0.1 - now()
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            let t = Date()
            do {
                _ = try await manager.process(samples: Array(samples[k * step..<end]))
                let p = await manager.getPartialTranscript()
                if p != lastPartial { lastPartial = p; metrics.add { metrics.partials += 1 } }
            } catch { metrics.error("\(name) process \(clip.id): \(error)") }
            let ms = Date().timeIntervalSince(t) * 1000
            metrics.add { metrics.processMs.append(ms) }
            k += 1
        }
        do {
            let (text, _) = try await manager.finishWithTokenTimings()
            metrics.add { metrics.finals += 1 }
            _ = text
        } catch { metrics.error("\(name) finish \(clip.id): \(error)") }
        await manager.reset()
        metrics.add { metrics.queued += 1 }
        pending.append(Task {
            do {
                let (text, pk) = try await serial.final(samples)
                metrics.add { metrics.parakeetMs.append(pk); metrics.parakeetDone += 1 }
                let (_, pol) = try await serial.polish(text)
                metrics.add { metrics.polishMs.append(pol); metrics.polishDone += 1 }
            } catch { metrics.error("\(name) final/polish \(clip.id): \(error)") }
            metrics.add { metrics.queued -= 1 }
        })
        try? await Task.sleep(nanoseconds: UInt64((0.5 + Double(index % 5) * 0.25) * 1e9))
    }
    for p in pending { await p.value }
}

// MARK: once-a-minute report

func report(_ label: String) {
    let w = metrics.drain()
    var queued = 0, partials = 0, finals = 0, pkDone = 0, polDone = 0
    metrics.add { queued = metrics.queued; partials = metrics.partials; finals = metrics.finals; pkDone = metrics.parakeetDone; polDone = metrics.polishDone }
    func f(_ v: [Double]) -> String { v.isEmpty ? "-/-" : String(format: "%.0f/%.0f", pct(v, 0.5), pct(v, 0.9)) }
    log(String(format: "%@ footprint %.0f MB rss %.0f MB mlx_active %.0f MB mlx_peak %.0f MB | partials %d finals %d parakeet %d polish %d queued %d | parakeet_ms p50/p90 %@ (n=%d) polish_ms p50/p90 %@ (n=%d) | process_ms p50/p90 %@ max %.0f | errors %d",
        label, physFootprintMB(), rssMB(), Double(Memory.activeMemory) / 1_048_576, Double(Memory.peakMemory) / 1_048_576,
        partials, finals, pkDone, polDone, queued, f(w.pk), w.pk.count, f(w.pol), w.pol.count, f(w.proc), w.proc.max() ?? 0, w.errs.count))
}

/// Peak phys_footprint seen by a 2 s sampler (the minute lines only show instants).
final class Peak: @unchecked Sendable { var mb = 0.0 }
let peak = Peak()
let sampler = Task {
    while !Task.isCancelled {
        peak.mb = max(peak.mb, physFootprintMB())
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
}

let reporter = Task {
    var n = 0
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        if Task.isCancelled { break }
        n += 1
        report("min \(n)")
    }
}

log("streaming starts: 'You' and 'Them' in real time")
async let a: Void = runStream("You", you, offset: 0, stride: 2)
async let b: Void = runStream("Them", them, offset: 7, stride: 2)
_ = await (a, b)
reporter.cancel(); sampler.cancel()
report("end")
var errs: [String] = []
metrics.add { errs = metrics.allErrors }
log("DONE errors total \(errs.count); sampled peak footprint \(String(format: "%.0f", peak.mb)) MB; process peak rss \(String(format: "%.0f", { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1_048_576 }())) MB")
