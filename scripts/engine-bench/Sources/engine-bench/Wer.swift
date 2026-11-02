import FluidAudio
import Foundation

struct WerHyp: Codable { let id: String; let raw: String; let text: String; let lang: String?; let ms: Int }

/// Runs manifest clips through the streaming manager (whole clip pushed at once; "ms" is push + finish).
/// language: pinned = each clip's own language, de / en = only that language's clips, auto = auto prompt.
func runWer(_ args: Args) async throws {
    let chunk = args.int("chunk", 560)
    let language = args.str("language", "pinned")
    let ship = args.str("ship", "latin")
    let manifestURL = URL(fileURLWithPath: args.str("manifest", "\(benchRoot)/data/manifest.jsonl"))
    let dataDir = manifestURL.deletingLastPathComponent()
    let label = "native-nemotron-\(chunk)-\(language)" + (ship == "latin" ? "" : "-\(ship)")
    let outDir = URL(fileURLWithPath: args.positional.first ?? "\(benchRoot)/results/work/\(label)")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let out = outDir.appendingPathComponent("hyp-\(label).jsonl")

    var clips = try loadManifest(manifestURL)
    if let sets = args.options["sets"] {
        let want = Set(sets.split(separator: ",").map(String.init))
        clips = clips.filter { want.contains($0.dataset ?? "") }
    }
    if language == "de" || language == "en" { clips = clips.filter { $0.lang == language } }
    if let kinds = args.options["kinds"] { clips = clips.filter { kinds.split(separator: ",").map(String.init).contains($0.kind ?? "") } }
    else { clips = clips.filter { $0.kind != "long" } }
    if let limit = args.options["limit"].flatMap({ Int($0) }) {  // first N per dataset+lang, for a quick look
        var seen: [String: Int] = [:]
        clips = clips.filter { c in
            let key = "\(c.dataset ?? "")-\(c.lang)"
            seen[key, default: 0] += 1
            return seen[key]! <= limit
        }
    }

    var done = Set<String>()
    if let existing = try? String(contentsOf: out, encoding: .utf8) {
        for line in existing.split(separator: "\n") {
            if let h = try? JSONDecoder().decode(WerHyp.self, from: Data(line.utf8)) { done.insert(h.id) }
        }
    } else {
        FileManager.default.createFile(atPath: out.path, contents: nil)
    }
    let todo = clips.filter { !done.contains($0.id) }
    say("\(label): \(todo.count) clips to do, \(done.count) already done -> \(out.path)")
    if todo.isEmpty { return }

    let manager = try await loadManager(chunk: chunk, ship: ship)
    // Warm the Core ML graphs so the first clip's ms isn't a compile.
    _ = try await manager.process(samples: [Float](repeating: 0, count: 16000))
    _ = try await manager.finish()
    await manager.reset()

    let handle = try FileHandle(forWritingTo: out)
    handle.seekToEndOfFile()
    var currentLocale = "", leaks = 0, total = 0.0
    for (i, clip) in todo.enumerated() {
        let want = language == "auto" ? "auto" : locale(clip.lang)
        if want != currentLocale { await manager.setLanguage(want); currentLocale = want }
        let samples = try readSamples(dataDir.appendingPathComponent(clip.wav))
        let t = Date()
        _ = try await manager.process(samples: samples)
        let text = try await manager.finish()
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        let detected = await manager.lastDecodeStats().detectedLanguage
        await manager.reset()
        if hasNonLatin(text) { leaks += 1 }
        total += Double(ms) / 1000
        let h = WerHyp(id: clip.id, raw: text, text: text, lang: detected, ms: ms)
        handle.write(try jsonLine(h))
        if i % 25 == 0 || i == todo.count - 1 {
            say("[\(i + 1)/\(todo.count)] \(clip.id) \(ms) ms \(detected ?? "-")  \(text.prefix(70))")
        }
    }
    try handle.close()
    say(String(format: "done: %d clips, %.1f s processing, %d with non-Latin letters", todo.count, total, leaks))
}
