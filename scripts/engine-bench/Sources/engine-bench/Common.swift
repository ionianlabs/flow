import FluidAudio
import Foundation

// The bench harness checkout (branch `bench`), next to this repo by default; FLOW_BENCH overrides it.
let benchRoot = ProcessInfo.processInfo.environment["FLOW_BENCH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("flow-bench/bench").path

struct Clip: Decodable {
    let id: String
    let dataset: String?
    let lang: String
    let kind: String?
    let wav: String
    let ref: String?
    let seconds: Double?
}

func loadManifest(_ url: URL) throws -> [Clip] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
}

func say(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(2)
}

/// Minimal "--flag value" parser: positionals and options.
struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            if raw[i].hasPrefix("--") {
                let key = String(raw[i].dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") { options[key] = raw[i + 1]; i += 1 } else { options[key] = "" }
            } else {
                positional.append(raw[i])
            }
            i += 1
        }
    }
    func int(_ key: String, _ def: Int) -> Int { options[key].flatMap { Int($0) } ?? def }
    func str(_ key: String, _ def: String) -> String { options[key] ?? def }
}

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

/// Locale code for the model's prompt: "de" -> "de-DE", "en" -> "en-US", "auto" -> "auto".
func locale(_ lang: String) -> String {
    switch lang {
    case "de": return "de-DE"
    case "en": return "en-US"
    default: return lang
    }
}

/// The Latin-script ship (en, es, fr, it, pt, de; vocab-pruned, so it can't emit other scripts) or the
/// full multilingual one. The app only needs Latin, like the Python engine's latin-only token block.
func loadManager(chunk: Int, ship: String = "latin") async throws -> StreamingNemotronMultilingualAsrManager {
    let t = Date()
    let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
        languageCode: ship == "latin" ? "de" : "auto", chunkMs: chunk)
    let manager = StreamingNemotronMultilingualAsrManager()
    try await manager.loadModels(from: dir)
    say(String(format: "loaded %@ ship @ %d ms in %.1f s (%@)", ship, chunk, Date().timeIntervalSince(t), dir.path))
    return manager
}

let converter = AudioConverter()
func readSamples(_ url: URL) throws -> [Float] { try converter.resampleAudioFile(url) }

/// A letter outside Basic Latin, Latin-1 and Latin Extended (the former Python server.py's NON_LATIN).
func hasNonLatin(_ text: String) -> Bool {
    text.unicodeScalars.contains { s in
        CharacterSet.letters.contains(s) && !(s.value <= 0x24F || (0x1E00...0x1EFF).contains(s.value))
    }
}

let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
}()

func jsonLine<T: Encodable>(_ v: T) throws -> Data { try jsonEncoder.encode(v) + Data("\n".utf8) }

/// Words as the user sees them, with each word's end time, from token timings: a "▁" or leading space
/// starts a word. Tokens with no letters/digits (lone punctuation) join the previous word.
func wordEnds(_ timings: [TokenTiming]) -> [(word: String, start: Double, end: Double)] {
    var out: [(String, Double, Double)] = []
    var pendingStart: Double?  // a lone "▁" token: the next piece starts a word
    for t in timings {
        let startsWord = t.token.hasPrefix("▁") || t.token.hasPrefix(" ")
        let piece = t.token.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
        if piece.isEmpty {
            if startsWord { pendingStart = t.startTime }
            continue
        }
        if startsWord || pendingStart != nil || out.isEmpty {
            out.append((piece, pendingStart ?? t.startTime, t.endTime))
            pendingStart = nil
        } else {
            out[out.count - 1].0 += piece
            out[out.count - 1].2 = t.endTime
        }
    }
    return out
}

func normWords(_ s: String) -> [String] {
    s.lowercased().unicodeScalars
        .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        .map(String.init).joined().split(separator: " ").map(String.init)
}
