import Foundation

/// --transcribetest YOU.wav [THEM.wav] [--no-parakeet]: transcription mode on WAV files
/// (16 kHz mono Int16) instead of the mic and the system audio, on the native engine,
/// at 4x real time. Prints the segments and the Markdown.
func runTranscribeTest(_ args: [String]) {
    Settings.registerDefaults()
    let files = args.filter { !$0.hasPrefix("--") }
    guard let youFile = files.first, let you = loadWAV(youFile) else {
        print("usage: --transcribetest YOU.wav [THEM.wav] [--no-parakeet]")
        exit(2)
    }
    let them = files.dropFirst().first.flatMap(loadWAV)
    let engine = NativeEngine(finalizer: ParakeetFinalizer())
    let t = Transcriber(engine: engine, mic: AudioCapture())
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ionian-flow-transcribetest.md")
    let started = Date()
    t.onFinished = {
        print(String(format: "finished %.1f s after the start", Date().timeIntervalSince(started)))
        report(t, started)
    }
    let go = {
        t.startForFiles(them: them != nil, file: file)
        print("finals from \(t.finalPass.isReady ? "Parakeet" : "the engine's live final"), cleanup \(t.cleanupAvailable ? "on" : "off")")
        print("vault \(VaultTags.root()?.path ?? "none"), its tags: \(VaultTags.common().joined(separator: ", "))")
        Thread {
            let tail = [Int16](repeating: 0, count: 32_000)  // 2 s of silence closes the last segment
            let a = you + tail, b = (them ?? []) + tail
            let step = 1_600
            let t0 = Date()
            let speed = Double(ProcessInfo.processInfo.environment["IONIAN_GATE_SPEED"] ?? "") ?? 4
            for i in stride(from: 0, to: max(a.count, b.count), by: step) {
                t.feedFile(.you, chunk(a, i, step))
                if them != nil { t.feedFile(.them, chunk(b, i, step)) }
                // Against the clock, not a sleep per chunk: the feed work itself would add up to a growing lag.
                let due = t0.addingTimeInterval(Double(i + step) / 16_000 / speed)
                Thread.sleep(forTimeInterval: max(0, due.timeIntervalSinceNow))
            }
            DispatchQueue.main.async { t.stop() }
        }.start()
    }
    var launched = false
    let log = EventLog(ProcessInfo.processInfo.environment["IONIAN_GATE_LOG"])
    engine.onEvent = { event in
        log.record(event, since: started)
        if case .ready = event, !launched {
            launched = true
            Task {
                await Segmenter.prepare()
                print(Segmenter.shared == nil ? "segmenter: energy gate" : "segmenter: Silero VAD")
                DispatchQueue.main.async {
                    if args.contains("--no-parakeet") { go() } else { t.finalPass.prepare { _ in go() } }
                }
            }
        } else {
            _ = t.handleMain(event)
        }
    }
    engine.start()
    dispatchMain()
}

/// IONIAN_GATE_LOG=<dir>: events.csv with the wall time of every final and polished event next to the
/// audio times of its segment, to read the lag between a segment's end and its text.
private final class EventLog {
    private let handle: FileHandle?
    init(_ dir: String?) {
        guard let dir else { handle = nil; return }
        let path = dir + "/events.csv"
        FileManager.default.createFile(atPath: path, contents: Data("t,kind,channel,segment,start,end\n".utf8))
        handle = FileHandle(forWritingAtPath: path)
    }
    func record(_ event: EngineEvent, since t0: Date) {
        guard let handle else { return }
        let t = String(format: "%.3f", Date().timeIntervalSince(t0))
        var line: String?
        switch event {
        case .final(let s, let segment, _, _, let a, let b): line = "\(t),final,\(s.channel),\(segment),\(a ?? -1),\(b ?? -1)"
        case .polished(let id, _): line = "\(t),polished,,\(id),,"
        default: break
        }
        if let line { handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)) }
    }
}

/// Prints the segments and the file once the summary is in (or failed).
private func report(_ t: Transcriber, _ started: Date) {
    guard !t.model.summarizing else {
        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { report(t, started) }
    }
    print(String(format: "summary done %.1f s after the start", Date().timeIntervalSince(started)))
    for s in t.model.segments.sorted(by: { $0.start < $1.start }) {
        print(String(format: "%@ %6.1f–%6.1f s  %@  %@", s.speaker.rawValue, s.start.timeIntervalSince(t.model.started),
                     s.end.timeIntervalSince(t.model.started), "\(s.stage)", s.text))
    }
    print("\n" + TranscriptStore.markdown(t.model))
    exit(0)
}

private func loadWAV(_ path: String) -> [Int16]? {
    guard let data = FileManager.default.contents(atPath: path), data.count > 44 else { return nil }
    return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

private func chunk(_ s: [Int16], _ i: Int, _ n: Int) -> Data {
    let part = i < s.count ? Array(s[i..<min(i + n, s.count)]) : []
    let padded = part + [Int16](repeating: 0, count: n - part.count)
    return padded.withUnsafeBufferPointer { Data(buffer: $0) }
}
