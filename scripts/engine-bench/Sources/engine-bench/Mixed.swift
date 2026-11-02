import FluidAudio
import Foundation

struct MixedPart: Codable { let lang: String; let ref: String }
struct MixedClip: Codable { let id: String; let wav: String; let parts: [MixedPart] }
struct MixedHyp: Codable { let id: String; let text: String; let lang: String? }

func writeWav(_ samples: [Float], to url: URL) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2)); d.append(contentsOf: "WAVEfmt ".utf8)
    u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    d.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
    try d.write(to: url)
}

let denglisch: [(String, String)] = [
    ("denglisch-0", "Lena hat gestern das neue Feature im Pull Request reviewed und danach das Deployment auf Kubernetes gestartet."),
    ("denglisch-1", "Wir müssen das Meeting mit Marco verschieben, weil der Server von Northwind Logistics ein Update braucht."),
    ("denglisch-2", "Kannst du mir bitte den Link zum Dashboard schicken, dann schaue ich mir die Metriken im Backlog an."),
    ("denglisch-3", "Das Team hat das Sprint Review gemacht und die Roadmap für ACME noch einmal angepasst."),
]

/// Words of each part found in the hypothesis, as a fraction (a dropped segment shows as a low part recall).
func partRecall(_ part: MixedPart, _ text: String) -> Double {
    let want = normWords(part.ref)
    let have = Set(normWords(text))
    return want.isEmpty ? 1 : Double(want.filter { have.contains($0) }.count) / Double(want.count)
}

func scoreMixed(_ dir: URL) throws {
    let clips = try String(contentsOf: dir.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(MixedClip.self, from: Data($0.utf8)) }
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("hyp-") && $0.hasSuffix(".jsonl") }.sorted()
    for f in files {
        let hyps = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(MixedHyp.self, from: Data($0.utf8)) }
        let by = Dictionary(uniqueKeysWithValues: hyps.map { ($0.id, $0) })
        say("\n=== \(f)")
        var worst: [Double] = [], leaks = 0
        for c in clips {
            guard let h = by[c.id] else { continue }
            let rec = c.parts.map { partRecall($0, h.text) }
            worst.append(rec.min() ?? 1)
            let leak = hasNonLatin(h.text)
            if leak { leaks += 1 }
            say(String(format: "%@ lang=%@ recall per part %@%@\n    %@", c.id.padding(toLength: 12, withPad: " ", startingAt: 0),
                       h.lang ?? "-", rec.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: "/"),
                       leak ? "  NON-LATIN" : "", String(h.text.prefix(220))))
        }
        say(String(format: "mean worst-part recall %.0f%%, %d with non-Latin letters, %d of %d clips below 60%% in some part",
                   (worst.reduce(0, +) / Double(max(1, worst.count))) * 100, leaks, worst.filter { $0 < 0.6 }.count, worst.count))
    }
}

/// mixed DIR: builds code-switching clips in DIR (wav/, manifest.jsonl) if missing, runs them in auto mode
/// (hyp-native-<chunk>[-ship].jsonl) and scores every hyp-*.jsonl in DIR (the Python server's too, see pybench.py).
func runMixed(_ args: Args) async throws {
    guard let dirPath = args.positional.first else { fail("usage: engine-bench mixed DIR [--chunk 560] [--ship latin|multilingual] [--score]") }
    let dir = URL(fileURLWithPath: dirPath)
    let wavDir = dir.appendingPathComponent("wav")
    try FileManager.default.createDirectory(at: wavDir, withIntermediateDirectories: true)
    let manifestURL = dir.appendingPathComponent("manifest.jsonl")
    if !FileManager.default.fileExists(atPath: manifestURL.path) {
        let all = try loadManifest(URL(fileURLWithPath: "\(benchRoot)/data/manifest.jsonl"))
        let data = URL(fileURLWithPath: "\(benchRoot)/data")
        func pick(_ lang: String, _ n: Int) -> [Clip] {
            Array(all.filter { $0.dataset == "fleurs" && $0.lang == lang && ($0.seconds ?? 99) < 11 }.dropFirst(20).prefix(n))
        }
        var clips: [MixedClip] = []
        let gap = [Float](repeating: 0, count: 12800)  // 0.8 s
        for (n, (a, b)) in zip(pick("de", 3), pick("en", 3)).enumerated() {
            for (tag, first, second) in [("de-en", a, b), ("en-de", b, a)] {
                let id = "concat-\(tag)-\(n)"
                let s = try readSamples(data.appendingPathComponent(first.wav)) + gap + readSamples(data.appendingPathComponent(second.wav))
                try writeWav(s, to: wavDir.appendingPathComponent("\(id).wav"))
                clips.append(MixedClip(id: id, wav: "wav/\(id).wav", parts: [
                    MixedPart(lang: first.lang, ref: first.ref ?? ""), MixedPart(lang: second.lang, ref: second.ref ?? "")]))
            }
        }
        for (id, text) in denglisch {
            let aiff = wavDir.appendingPathComponent("\(id).aiff")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "Anna", "-o", aiff.path, "--data-format=LEI16@16000", text]
            try p.run(); p.waitUntilExit()
            try writeWav(try readSamples(aiff), to: wavDir.appendingPathComponent("\(id).wav"))
            try? FileManager.default.removeItem(at: aiff)
            clips.append(MixedClip(id: id, wav: "wav/\(id).wav", parts: [MixedPart(lang: "de", ref: text)]))
        }
        try clips.reduce(Data()) { $0 + (try jsonLine($1)) }.write(to: manifestURL)
        say("built \(clips.count) clips in \(dir.path)")
    }
    if args.options["score"] == nil {
        let chunk = args.int("chunk", 560), ship = args.str("ship", "latin")
        let clips = try String(contentsOf: manifestURL, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(MixedClip.self, from: Data($0.utf8)) }
        let manager = try await loadManager(chunk: chunk, ship: ship)
        await manager.setLanguage("auto")
        var lines = Data()
        for c in clips {
            let samples = try readSamples(dir.appendingPathComponent(c.wav))
            _ = try await manager.process(samples: samples)
            let text = try await manager.finish()
            let lang = await manager.lastDecodeStats().detectedLanguage
            await manager.reset()
            lines += try jsonLine(MixedHyp(id: c.id, text: text, lang: lang))
        }
        try lines.write(to: dir.appendingPathComponent("hyp-native-\(chunk)\(ship == "latin" ? "" : "-" + ship).jsonl"))
    }
    try scoreMixed(dir)
}
