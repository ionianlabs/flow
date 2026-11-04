import Foundation

// Word error rate scoring, a port of what the Python bench scripts did (asr/bench_wer.normalize, jiwer's
// corpus WER, the former Python scorers). CLI flags: --score-dictation,
// --compare-transcribe, --make-two-speaker. The Python files are gone; WERScoreTests pins the numbers.

enum WERScore {
    // MARK: normalize + WER

    /// Python's str.isspace (and so regex \s): White_Space plus U+001C..U+001F.
    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || (0x1C...0x1F).contains(s.value)
    }

    /// Python's regex \w: letters, numbers (any category L* / N*) and underscore.
    private static func isWord(_ s: Unicode.Scalar) -> Bool {
        if s == "_" { return true }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// str.lower(): full case mapping, and Σ becomes ς when it ends a word (preceded by a cased letter, not followed by one;
    /// case-ignorable characters are skipped), which String.lowercased() does not do.
    private static func lowerLikePython(_ text: String) -> String {
        let sc = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, s) in sc.enumerated() {
            guard s == "\u{3A3}" else { out.append(contentsOf: String(s).lowercased().unicodeScalars); continue }
            var j = i - 1
            while j >= 0, sc[j].properties.isCaseIgnorable { j -= 1 }
            let before = j >= 0 && sc[j].properties.isCased
            var k = i + 1
            while k < sc.count, sc[k].properties.isCaseIgnorable { k += 1 }
            let after = k < sc.count && sc[k].properties.isCased
            out.append(before && !after ? "\u{3C2}" : "\u{3C3}")
        }
        return String(out)
    }

    /// Lowercase, no punctuation, one space: FLEURS' "transcription" field is already like that.
    /// NFKC, lower, drop ’ ' ` ´, every other non-word non-space character (and "_") becomes a space.
    static func normalize(_ text: String) -> String {
        let lower = lowerLikePython(text.precomposedStringWithCompatibilityMapping)
        var words: [String] = []
        var cur = String.UnicodeScalarView()
        func flush() { if !cur.isEmpty { words.append(String(cur)); cur = String.UnicodeScalarView() } }
        for s in lower.unicodeScalars {
            if s == "\u{2019}" || s == "'" || s == "`" || s == "\u{B4}" { continue }
            if isSpace(s) || s == "_" || !isWord(s) { flush() } else { cur.append(s) }
        }
        flush()
        return words.joined(separator: " ")
    }

    /// Levenshtein distance between two token lists (substitution, insertion, deletion all cost 1).
    static func edits<T: Equatable>(_ ref: [T], _ hyp: [T]) -> Int {
        var d = Array(0...hyp.count)
        for (i, r) in ref.enumerated() {
            var prev = d[0]
            d[0] = i + 1
            for (j, h) in hyp.enumerated() {
                let old = d[j + 1]
                d[j + 1] = min(d[j + 1] + 1, d[j] + 1, prev + (r == h ? 0 : 1))
                prev = old
            }
        }
        return d[hyp.count]
    }

    static func words(_ text: String) -> [String] { normalize(text).split(separator: " ").map(String.init) }

    /// Corpus WER in percent (sum of edits over sum of reference words), nil when there are no reference words.
    static func wer(refs: [String], hyps: [String]) -> Double? {
        var e = 0, n = 0
        for (r, h) in zip(refs, hyps) {
            let rw = words(r)
            e += edits(rw, words(h))
            n += rw.count
        }
        return n > 0 ? 100 * Double(e) / Double(n) : nil
    }

    // MARK: helpers

    private static func readLines(_ path: String) -> [String]? {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); return nil
        }
        return t.components(separatedBy: "\n")
    }

    /// JSONL keyed by "id", in file order (a later duplicate replaces the earlier record, like a Python dict).
    private static func loadJSONL(_ path: String) -> (ids: [String], rows: [String: [String: Any]])? {
        guard let lines = readLines(path) else { return nil }
        var ids: [String] = [], rows: [String: [String: Any]] = [:]
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = o["id"] as? String else { continue }
            if rows[id] == nil { ids.append(id) }
            rows[id] = o
        }
        return (ids, rows)
    }

    private static func pad(_ s: String, _ width: Int, left: Bool = true) -> String {
        let fill = String(repeating: " ", count: max(0, width - s.count))
        return left ? s + fill : fill + s
    }

    private static func f2(_ v: Double, _ width: Int = 0) -> String { String(format: "%\(width).2f", v) }

    // MARK: --score-dictation MANIFEST.jsonl E2E.jsonl [OTHER.jsonl[:label] ...]

    /// WER of the e2e dictation run against the manifest references, per dataset and language, next to other
    /// hypothesis files on the same clips. Returns the printed table (also used by the unit tests).
    static func scoreDictationTable(manifest: [String: [String: Any]], runs: [(label: String, ids: [String], rows: [String: [String: Any]])]) -> String {
        var groups: [[String]: [String]] = [:]
        for id in runs[0].ids {
            guard let m = manifest[id], let ds = m["dataset"] as? String, let lang = m["lang"] as? String else { continue }
            groups[[ds, lang], default: []].append(id)
            groups[["all", lang], default: []].append(id)
            groups[["all", "all"], default: []].append(id)
        }
        var out = pad("group", 18) + " " + pad("clips", 5, left: false) + " " + runs.map { pad($0.label, 12, left: false) }.joined(separator: " ") + "\n"
        for key in groups.keys.sorted(by: { ($0[0], $0[1]) < ($1[0], $1[1]) }) {
            var cells: [String] = []
            for run in runs {
                var e = 0, n = 0
                for id in groups[key]! {
                    guard let h = run.rows[id] else { continue }
                    let ref = words(manifest[id]?["ref"] as? String ?? "")
                    e += edits(ref, words(h["text"] as? String ?? ""))
                    n += ref.count
                }
                cells.append(n > 0 ? f2(100 * Double(e) / Double(n), 11) + "%" : pad("-", 12, left: false))
            }
            out += pad(key.joined(separator: "/"), 18) + " " + pad(String(groups[key]!.count), 5, left: false) + " " + cells.joined(separator: " ") + "\n"
        }
        return out
    }

    static func scoreDictationCLI(_ args: [String]) -> Int32 {
        guard args.count >= 2, let man = loadJSONL(args[0]), let e2e = loadJSONL(args[1]) else {
            FileHandle.standardError.write(Data("usage: IonianFlow --score-dictation MANIFEST.jsonl E2E.jsonl [OTHER.jsonl[:label] ...]\n".utf8)); return 2
        }
        var runs = [(label: "e2e", ids: e2e.ids, rows: e2e.rows)]
        for spec in args.dropFirst(2) {
            let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let o = loadJSONL(parts[0]) else { return 1 }
            let label = parts.count > 1 && !parts[1].isEmpty ? parts[1] : URL(fileURLWithPath: parts[0]).deletingPathExtension().lastPathComponent
            runs.append((label, o.ids, o.rows))
        }
        print(scoreDictationTable(manifest: man.rows, runs: runs), terminator: "")
        return 0
    }

    // MARK: --compare-transcribe TRUTH.json NEW.log OLD.log

    struct Seg { var speaker: String; var start: Double; var end: Double; var stage: String; var text: String }

    private static let segLine = try! NSRegularExpression(pattern: #"^(You|Them)\s+([\d.]+)–\s*([\d.]+) s\s+(\S+)\s+(.*)$"#)

    /// Segment lines ("You  12.3– 15.1 s  final  text") of a --transcribetest log, sorted by start.
    static func segments(log: String) -> [Seg] {
        var out: [Seg] = []
        for line in log.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = segLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let a = Double(ns.substring(with: m.range(at: 2))), let b = Double(ns.substring(with: m.range(at: 3))) else { continue }
            out.append(Seg(speaker: ns.substring(with: m.range(at: 1)), start: a, end: b, stage: ns.substring(with: m.range(at: 4)), text: ns.substring(with: m.range(at: 5))))
        }
        return out.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    private static func speakerWER(_ truth: [[String: Any]], _ segs: [Seg], _ who: String) -> (Double, Int) {
        let ref = words(truth.filter { ($0["speaker"] as? String ?? "").capitalized == who }.map { $0["ref"] as? String ?? "" }.joined(separator: " "))
        let hyp = words(segs.filter { $0.speaker == who }.map(\.text).joined(separator: " "))
        return (100 * Double(edits(ref, hyp)) / Double(max(1, ref.count)), ref.count)
    }

    private static func deltas(_ a: [Seg], _ b: [Seg]) -> ([Double], [Double]) {
        var ds: [Double] = [], de: [Double] = []
        for s in a {
            let cand = b.filter { $0.speaker == s.speaker && abs($0.start - s.start) < 3 }
            if let t = cand.min(by: { abs($0.start - s.start) < abs($1.start - s.start) }) {
                ds.append(abs(t.start - s.start)); de.append(abs(t.end - s.end))
            }
        }
        return (ds, de)
    }

    private static func quantile(_ v: [Double], _ p: Double) -> Double {
        v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count) * p))]
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        return n == 0 ? .nan : n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private static let mdBlock = try! NSRegularExpression(pattern: #"^\*\*(You|Them)\*\* · \d\d:\d\d$"#, options: .anchorsMatchLines)

    static func compareTranscribeCLI(_ args: [String]) -> Int32 {
        guard args.count == 3, let truthData = FileManager.default.contents(atPath: args[0]),
              let truth = try? JSONSerialization.jsonObject(with: truthData) as? [[String: Any]],
              let newLog = try? String(contentsOfFile: args[1], encoding: .utf8), let oldLog = try? String(contentsOfFile: args[2], encoding: .utf8) else {
            FileHandle.standardError.write(Data("usage: IonianFlow --compare-transcribe TRUTH.json NEW.log OLD.log\n".utf8)); return 2
        }
        let new = segments(log: newLog), old = segments(log: oldLog)
        let you = truth.filter { $0["speaker"] as? String == "you" }.count
        let them = truth.filter { $0["speaker"] as? String == "them" }.count
        print("truth turns \(truth.count) (\(you) you, \(them) them)")
        for (label, segs) in [("new", new), ("old", old)] {
            let parts = ["You", "Them"].map { w -> String in
                let (v, n) = speakerWER(truth, segs, w)
                return "WER \(w) \(f2(v))% of \(n) words"
            }
            print("\(label): \(segs.count) segments (\(segs.filter { $0.speaker == "You" }.count) You, \(segs.filter { $0.speaker == "Them" }.count) Them), " + parts.joined(separator: ", "))
        }
        let orderNew = Array(new.map { String($0.speaker.first!) }), orderOld = Array(old.map { String($0.speaker.first!) })
        print("speaker order identical: \(orderNew == orderOld ? "True" : "False") (edit distance \(edits(orderNew, orderOld)) of \(orderOld.count))")
        let (ds, de) = deltas(new, old)
        print("new vs old, matched \(ds.count)/\(new.count): start offset median \(f2(median(ds))) s p90 \(f2(quantile(ds, 0.9))) max \(f2(ds.max() ?? .nan)); "
              + "end offset median \(f2(median(de))) s p90 \(f2(quantile(de, 0.9))) max \(f2(de.max() ?? .nan))")
        func blocks(_ t: String) -> [String] {
            let ns = t as NSString
            return mdBlock.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        let bn = blocks(newLog), bo = blocks(oldLog)
        print("Markdown speaker blocks: new \(bn.count), old \(bo.count), same order: \(bn == bo ? "True" : "False")")
        let speed = Double(ProcessInfo.processInfo.environment["IONIAN_GATE_SPEED"] ?? "") ?? 4
        if speed != 1 { print("note: the harness feeds files at \(speed)x real time, so segment times are on a compressed wall-clock axis; only new-vs-old is meaningful.") }
        return 0
    }

    // MARK: --make-two-speaker MANIFEST.jsonl OUTDIR [--seconds 600] [--seed 7] [--overlap-every 9]

    /// SplitMix64: a small seeded generator (the picks differ from the old Python script's Mersenne Twister).
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static func readWav16k(_ url: URL) -> [Int16]? {
        guard let d = try? Data(contentsOf: url), d.count > 44, d[0..<4] == Data("RIFF".utf8) else { return nil }
        var i = 12
        var fmt: (ch: UInt16, rate: UInt32, bits: UInt16)?
        func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        while i + 8 <= d.count {
            let id = String(decoding: d[i..<i + 4], as: UTF8.self), size = Int(u32(i + 4)), body = i + 8
            if id == "fmt " { fmt = (u16(body + 2), u32(body + 4), u16(body + 14)) }
            if id == "data" {
                guard let f = fmt, f.ch == 1, f.rate == 16000, f.bits == 16 else { return nil }
                let n = min(size, d.count - body) / 2
                return (0..<n).map { Int16(bitPattern: u16(body + 2 * $0)) }
            }
            i = body + size + (size & 1)
        }
        return nil
    }

    private static func writeWav16k(_ url: URL, _ samples: ArraySlice<Int16>) throws {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(Data("RIFF".utf8)); put32(36 + bytes); d.append(Data("WAVEfmt ".utf8)); put32(16)
        put16(1); put16(1); put32(16000); put32(32000); put16(2); put16(16)
        d.append(Data("data".utf8)); put32(bytes)
        for s in samples { put16(UInt16(bitPattern: s)) }
        try d.write(to: url)
    }

    /// Builds you.wav, them.wav (16 kHz mono Int16, same length) and truth.json from FLEURS clips: alternating
    /// turns, silence between them, every Nth turn overlapping the previous. Feed to `--transcribetest`.
    /// MANIFEST lines: id, dataset, lang, kind, wav (relative to the manifest), ref. No invented audio.
    static func makeTwoSpeakerCLI(_ args: [String]) -> Int32 {
        var pos: [String] = [], seconds = 600.0, seed: UInt64 = 7, overlapEvery = 9
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
            case "--seed": seed = UInt64(it.next() ?? "") ?? seed
            case "--overlap-every": overlapEvery = Int(it.next() ?? "") ?? overlapEvery
            default: pos.append(a)
            }
        }
        guard pos.count == 2, let man = loadJSONL(pos[0]) else {
            FileHandle.standardError.write(Data("usage: IonianFlow --make-two-speaker MANIFEST.jsonl OUTDIR [--seconds 600] [--seed 7] [--overlap-every 9]\n".utf8)); return 2
        }
        let base = URL(fileURLWithPath: pos[0]).deletingLastPathComponent()
        var rng = SeededRNG(state: seed)
        var pool = man.ids.compactMap { man.rows[$0] }.filter {
            $0["dataset"] as? String == "fleurs" && $0["kind"] as? String == "clip" && ["de", "en"].contains($0["lang"] as? String ?? "")
        }
        pool.shuffle(using: &rng)
        let out = URL(fileURLWithPath: pos[1])
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let sr = 16000, total = Int(seconds * Double(sr))
            var you = [Int16](repeating: 0, count: total), them = you
            var truth: [[String: Any]] = []
            var t = 0.5
            var speaker = "you"
            for (turn, row) in pool.enumerated() {
                guard let wav = row["wav"] as? String, let audio = readWav16k(base.appendingPathComponent(wav)) else { continue }
                let start = Int(t * Double(sr))
                if start + audio.count > total { break }
                for (i, v) in audio.enumerated() { if speaker == "you" { you[start + i] = v } else { them[start + i] = v } }
                let end = Double(start + audio.count) / Double(sr)
                truth.append(["speaker": speaker, "start": (Double(start) / Double(sr) * 100).rounded() / 100, "end": (end * 100).rounded() / 100,
                              "lang": row["lang"] ?? "", "id": row["id"] ?? "", "ref": row["ref"] ?? ""])
                speaker = speaker == "you" ? "them" : "you"
                let overlap = overlapEvery > 0 && (turn + 1) % overlapEvery == 0
                t = overlap ? end - 1.5 : end + Double.random(in: 1.2...3.0, using: &rng)
            }
            guard let last = truth.compactMap({ $0["end"] as? Double }).max() else { print("no turns"); return 1 }
            let n = min(total, Int((last + 1) * Double(sr)))
            try writeWav16k(out.appendingPathComponent("you.wav"), you[0..<n])
            try writeWav16k(out.appendingPathComponent("them.wav"), them[0..<n])
            try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("truth.json"))
            var overlaps = 0
            for (a, b) in zip(truth, truth.dropFirst()) where (b["start"] as! Double) < (a["end"] as! Double) { overlaps += 1 }
            print("\(truth.count) turns, \(Int(last.rounded())) s, \(overlaps) overlaps")
            return 0
        } catch {
            FileHandle.standardError.write(Data("make-two-speaker: \(error)\n".utf8)); return 1
        }
    }
}
