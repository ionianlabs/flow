import Foundation

/// --segment-replay TRUTH.json YOU.wav [THEM.wav] [--enter P] [--exit P] [--pause S] [--cuts]: runs only the
/// Segmenter over the files, the old energy gate and the VAD, and compares the cuts with the turns of the truth
/// file (speaker, start, end): turns split inside, turns merged into the next one, turns whose segment is
/// emitted more than 3 s after the turn ended. Fast: the model is fed in lockstep, no ASR.
enum SegmenterReplay {
    struct Turn { let speaker: String; let start: Double; let end: Double }
    struct Cut { let at: Double; let detected: Double }

    static func cli(_ args: [String]) -> Int32 {
        func value(_ f: String) -> Double? { args.firstIndex(of: f).flatMap { i in args.indices.contains(i + 1) ? Double(args[i + 1]) : nil } }
        let files = args.filter { !$0.hasPrefix("--") && Double($0) == nil }
        guard files.count >= 2, let data = FileManager.default.contents(atPath: files[0]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("usage: --segment-replay TRUTH.json YOU.wav [THEM.wav] [--enter P] [--exit P] [--pause S] [--cuts]")
            return 2
        }
        let turns = json.compactMap { t -> Turn? in
            guard let s = t["speaker"] as? String, let a = t["start"] as? Double, let b = t["end"] as? Double else { return nil }
            return Turn(speaker: s, start: a, end: b)
        }
        let ready = DispatchSemaphore(value: 0)
        Task { await Segmenter.prepare(); ready.signal() }
        ready.wait()
        guard Segmenter.shared != nil else { print("VAD model unavailable"); return 1 }
        var settings = Segmenter.Settings()
        if let v = value("--enter") { settings.enter = Float(v) }
        if let v = value("--exit") { settings.exit = Float(v) }
        if let v = value("--pause") { settings.pause = v }
        if let v = value("--target") { settings.target = Float(v) }
        if let v = value("--minrms") { settings.minRMS = Float(v) }
        if let v = value("--maxgain") { settings.maxGain = Float(v) }
        slack = value("--slack") ?? 3.0
        verbose = args.contains("--late")
        var ok = true
        for (speaker, file) in zip(["you", "them"], files.dropFirst()) {
            guard let pcm = wav(file) else { print("cannot read \(file)"); ok = false; continue }
            let mine = turns.filter { $0.speaker == speaker }.sorted { $0.start < $1.start }
            print("\(speaker): \(mine.count) turns, \(String(format: "%.0f", Double(pcm.count) / 16_000)) s")
            for (name, energy) in [("energy", true), ("vad", false)] {
                let t0 = Date()
                let cuts = run(pcm, energy: energy, settings: settings)
                let wall = Date().timeIntervalSince(t0)
                print(report(name, cuts, mine, wall))
                if args.contains("--cuts") { print(cuts.map { String(format: "%.1f/%.1f", $0.at, $0.detected) }.joined(separator: " ")) }
            }
        }
        let c = Segmenter.cost
        print(String(format: "VAD frames %d, mean %.2f ms per 256 ms frame, worst %.1f ms", c.frames, 1000 * c.seconds / Double(max(1, c.frames)), 1000 * c.worst))
        return ok ? 0 : 1
    }

    static func run(_ pcm: [Int16], energy: Bool, settings: Segmenter.Settings) -> [Cut] {
        let seg = Segmenter()
        seg.energyOnly = energy
        seg.lockstep = true
        seg.settings = settings
        var cuts: [Cut] = []
        var fed = 0
        let step = 1_600
        for i in stride(from: 0, to: pcm.count, by: step) {
            let part = Array(pcm[i..<min(i + step, pcm.count)])
            fed += part.count
            let data = part.withUnsafeBufferPointer { Data(buffer: $0) }
            if let back = seg.feed(data) {
                cuts.append(Cut(at: Double(fed - back) / 16_000, detected: Double(fed) / 16_000))
            }
        }
        return cuts
    }

    nonisolated(unsafe) static var slack = 3.0
    nonisolated(unsafe) static var verbose = false  // truth ends carry trailing silence of the source clip
    static func report(_ name: String, _ cuts: [Cut], _ turns: [Turn], _ wall: Double) -> String {
        var split = 0, innerCuts = 0, merged = 0, late = 0
        var delays: [Double] = []
        for (k, t) in turns.enumerated() {
            let inner = cuts.filter { $0.at > t.start + 0.3 && $0.at < t.end - slack }.count
            innerCuts += inner
            if inner > 0 { split += 1 }
            if k + 1 < turns.count {
                let n = turns[k + 1]
                if !cuts.contains(where: { $0.at >= t.end - slack && $0.at <= n.start + 0.3 }) { merged += 1 }
            }
            if let c = cuts.first(where: { $0.at >= t.end - slack }) {
                let d = c.detected - t.end
                delays.append(d)
                if d > 3 { late += 1; if verbose { print(String(format: "    late turn %.1f-%.1f cut %.1f detected %.1f", t.start, t.end, c.at, c.detected)) } }
            } else { late += 1 }
        }
        delays.sort()
        let med = delays.isEmpty ? 0 : delays[delays.count / 2]
        return String(format: "  %@ cuts %3d  turns split %2d (%d inner cuts)  merged %2d  late>3s %2d  end delay median %.2f max %.1f  (%.1f s)",
                      name.padding(toLength: 7, withPad: " ", startingAt: 0), cuts.count, split, innerCuts, merged, late, med, delays.last ?? 0, wall)
    }

    static func wav(_ path: String) -> [Int16]? {
        guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return nil }
        return d.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// 16 kHz mono Int16 samples of a WAV file, found by its data chunk (clips may carry extra chunks).
    static func wavData(_ path: String) -> [Int16]? {
        guard let d = FileManager.default.contents(atPath: path), let r = d.range(of: Data("data".utf8)) else { return nil }
        return d[(r.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}
