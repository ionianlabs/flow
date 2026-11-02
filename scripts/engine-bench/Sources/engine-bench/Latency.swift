import FluidAudio
import Foundation

struct ClipLatency: Codable {
    let id: String
    let lang: String
    let text: String
    let firstPartialS: Double?  // wall time from the first pushed chunk to the first non-empty partial
    let firstWordStartS: Double?  // audio time the first word starts (for the speech-relative figure)
    let releaseToFinalMs: Double
    let lagsMs: [Double]  // per word: wall time it first showed in a partial minus the audio time it ends
    let words: [WordEnd]  // reference word end times (audio seconds) for the Python comparison
}
struct WordEnd: Codable { let word: String; let start: Double; let end: Double }

func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}

func summarize(_ label: String, _ results: [ClipLatency]) {
    let lags = results.flatMap { $0.lagsMs }
    let first = results.compactMap { r in r.firstPartialS.map { $0 * 1000 } }
    let firstRel = results.compactMap { r -> Double? in
        guard let a = r.firstPartialS, let b = r.firstWordStartS else { return nil }
        return (a - b) * 1000
    }
    let rel = results.map { $0.releaseToFinalMs }
    func f(_ v: [Double]) -> String {
        String(format: "median %5.0f  p90 %5.0f  (n=%d)", percentile(v, 0.5), percentile(v, 0.9), v.count)
    }
    say("== \(label)  [PROVISIONAL if the machine was busy]")
    say("  first partial after first audio (ms)   \(f(first))")
    say("  first partial after first word starts   \(f(firstRel))")
    say("  live lag per word (ms)                  \(f(lags))")
    say("  release to final (ms)                   \(f(rel))")
}

func runLatency(_ args: Args) async throws {
    let chunk = args.int("chunk", 560)
    let perLang = args.int("clips", 10)
    let ship = args.str("ship", "latin")
    let dataDir = URL(fileURLWithPath: "\(benchRoot)/data")
    let out = URL(fileURLWithPath: args.str("out", "/tmp/engine-bench-latency-native-\(chunk).json"))
    let all = try loadManifest(dataDir.appendingPathComponent("manifest.jsonl"))
    var clips: [Clip] = []
    for lang in ["de", "en"] {
        clips += all.filter { $0.dataset == "fleurs" && $0.lang == lang }.prefix(perLang)
    }
    let manager = try await loadManager(chunk: chunk, ship: ship)
    _ = try await manager.process(samples: [Float](repeating: 0, count: 16000))
    _ = try await manager.finish()
    await manager.reset()

    let step = 1600  // 100 ms, like the app's audio tap
    var results: [ClipLatency] = []
    for clip in clips {
        await manager.setLanguage(locale(clip.lang))
        let samples = try readSamples(dataDir.appendingPathComponent(clip.wav))
        var appeared: [Double] = []  // wall seconds at which word i first showed
        var firstPartial: Double?
        let t0 = DispatchTime.now().uptimeNanoseconds
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 }
        var k = 0
        while k * step < samples.count {
            let end = min(samples.count, (k + 1) * step)
            // the chunk is complete (spoken) at (k+1) * 100 ms
            let wait = Double(k + 1) * 0.1 - now()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            _ = try await manager.process(samples: Array(samples[k * step..<end]))
            let partial = await manager.getPartialTranscript()
            let n = partial.split(separator: " ").filter { $0.contains { $0.isLetter || $0.isNumber } }.count
            if n > 0, firstPartial == nil { firstPartial = now() }
            while appeared.count < n { appeared.append(now()) }
            k += 1
        }
        let release = now()
        let (text, timings) = try await manager.finishWithTokenTimings()
        let releaseMs = (now() - release) * 1000
        await manager.reset()
        let words = wordEnds(timings)
        if args.options["debug"] != nil { say(timings.prefix(14).map { "[\($0.token)]" }.joined()) }
        let lags = zip(appeared, words).map { ($0 - $1.end) * 1000 }
        let r = ClipLatency(
            id: clip.id, lang: clip.lang, text: text, firstPartialS: firstPartial,
            firstWordStartS: words.first?.start, releaseToFinalMs: releaseMs, lagsMs: lags,
            words: words.map { WordEnd(word: $0.word, start: $0.start, end: $0.end) })
        results.append(r)
        say(String(format: "%@  first %.2f s  release->final %.0f ms  lag median %.0f ms  words %d/%d",
                   clip.id, firstPartial ?? -1, releaseMs, percentile(lags, 0.5), appeared.count, words.count))
    }
    try jsonEncoder.encode(results).write(to: out)
    say("wrote \(out.path)")
    summarize("native @ \(chunk) ms, all", results)
    for lang in ["de", "en"] { summarize("native @ \(chunk) ms, \(lang)", results.filter { $0.lang == lang }) }
}
