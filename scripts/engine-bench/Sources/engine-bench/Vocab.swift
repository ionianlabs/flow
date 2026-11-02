import FluidAudio
import Foundation

/// Terms of a Vocabulary.md: the "- term" bullets (an "= alias" or "(note)" tail is dropped).
func vocabularyTerms(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("- ") || l.hasPrefix("* ") else { return nil }
        var t = String(l.dropFirst(2))
        for sep in [" = ", " (", " – ", " -> "] { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) } }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

/// vocab DIR: every clip with the bias off and with NemotronVocabularyBias at several per-token boosts.
/// The Python booster has two knobs (start 1.0 on a term's first characters, strength 3.0 once under way);
/// FluidAudio has one flat per-token bonus (its default 4.5, ceiling 6.0), so the settings below are flat
/// bonuses around the Python numbers. Score with: cd asr && uv run bench_vocab.py --score DIR
func runVocab(_ args: Args) async throws {
    guard let dirPath = args.positional.first else { fail("usage: engine-bench vocab DIR [--chunk 560]") }
    let dir = URL(fileURLWithPath: dirPath)
    let chunk = args.int("chunk", 560)
    let clips = try loadManifest(dir.appendingPathComponent("manifest.jsonl"))
    let terms = try vocabularyTerms(dir.appendingPathComponent("Vocabulary.md"))
    say("\(clips.count) clips, \(terms.count) terms: \(terms.joined(separator: ", "))")
    let settings: [(String, Float?)] = [("off", nil)] + args.str("boosts", "1,2,3,4.5").split(separator: ",")
        .compactMap { Float($0) }.map { ("bias\($0)", Optional($0)) }
    let manager = try await loadManager(chunk: chunk, ship: args.str("ship", "latin"))
    let audio = try clips.map { try readSamples(dir.appendingPathComponent($0.wav)) }
    _ = try await manager.process(samples: [Float](repeating: 0, count: 16000))
    _ = try await manager.finish()
    await manager.reset()

    for (name, boost) in settings {
        let label = "native\(chunk)-\(name)"
        let buildStart = Date()
        await manager.setCustomVocabulary(boost.map { b in terms.map { CustomVocabularyTerm(text: $0, weight: b) } } ?? [])
        let buildMs = Int(Date().timeIntervalSince(buildStart) * 1000)
        var lines = Data()
        let t = Date()
        var audioSeconds = 0.0
        var currentLocale = ""
        for (clip, samples) in zip(clips, audio) {
            let want = locale(clip.lang)
            if want != currentLocale { await manager.setLanguage(want); currentLocale = want }
            _ = try await manager.process(samples: samples)
            let text = try await manager.finish()
            await manager.reset()
            audioSeconds += Double(samples.count) / 16000
            lines += try jsonLine(["id": clip.id, "text": text])
        }
        let secs = Date().timeIntervalSince(t)
        try lines.write(to: dir.appendingPathComponent("hyp-\(label).jsonl"))
        say(String(format: "%@: %.1f s for %.0f s of audio (%.1fx realtime), bias build %d ms", label, secs, audioSeconds, audioSeconds / secs, buildMs))
    }
    await manager.setCustomVocabulary([])
}
