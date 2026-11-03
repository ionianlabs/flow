import FluidAudio
import Foundation
import MLX

// Integration step: end-to-end checks of the real engine in one process. One flag, several modes:
//   --e2e-engine load                                   cold/warm load times of the models, footprint
//   --e2e-engine reload                                 stop() then start() emits .ready again, capabilities refresh
//   --e2e-engine unload                                 Gemma memory before/after unload, through the engine's own Polisher/Summarizer and the sweep LLM
//   --e2e-engine dictation MANIFEST OUTDIR [perGroup]   dictation sessions paced in real time -> OUTDIR/e2e-dictation.jsonl
// Needs IONIAN_FLOW_TEST_DIR (Settings.testDir): the vocabulary file is read from there, never from the user's folders.

enum E2E {
    static func cli(_ args: [String]) -> Int32 {
        guard Settings.testDir != nil else {
            FileHandle.standardError.write(Data("--e2e-engine needs IONIAN_FLOW_TEST_DIR (a folder with an optional Vocabulary.md)\n".utf8))
            return 2
        }
        Settings.registerDefaults()
        Task.detached {
            let rc: Int32
            switch args.first {
            case "load": rc = await load()
            case "reload": rc = await reload()
            case "unload": rc = await unload()
            case "dictation" where args.count >= 3: rc = await dictation(args)
            default:
                FileHandle.standardError.write(Data("usage: --e2e-engine load|reload|unload|dictation MANIFEST OUTDIR [perGroup]\n".utf8))
                rc = 2
            }
            exit(rc)
        }
        dispatchMain()
    }

    private static func say(_ s: String) { print(s); fflush(stdout) }

    private static func mem() -> String {
        let a = Double(MLX.Memory.activeMemory) / 1_048_576, c = Double(MLX.Memory.cacheMemory) / 1_048_576
        return String(format: "mlx active %.0f MB cache %.0f MB, footprint %.0f MB", a, c, ModelHub.shared.footprintMB())
    }

    /// Events delivered on main, collected here.
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(Date, EngineEvent)] = []
        func add(_ e: EngineEvent) { lock.lock(); events.append((Date(), e)); lock.unlock() }
        func all() -> [(Date, EngineEvent)] { lock.lock(); defer { lock.unlock() }; return events }
        func clear() { lock.lock(); events = []; lock.unlock() }
        func waitReady(count: Int, timeout: Double) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if all().filter({ if case .ready = $0.1 { return true } else { return false } }).count >= count { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }
    }

    // MARK: load

    private static func load() async -> Int32 {
        let hub = ModelHub.shared
        say("footprint at start: \(mem())")
        do {
            for round in 1...2 {
                let t = Date()
                _ = try await hub.nemotron(.mic)
                say(String(format: "nemotron(.mic) load #%d: %.2f s", round, Date().timeIntervalSince(t)))
                if round == 1 { await hub.unload(.nemotronMic) }
            }
            let t = Date()
            _ = try await hub.parakeet()
            say(String(format: "parakeet+ctc load: %.2f s", Date().timeIntervalSince(t)))
            say("after: \(mem())")
        } catch { say("load failed: \(error)"); return 1 }
        return 0
    }

    // MARK: reload

    private static func reload() async -> Int32 {
        let inbox = Inbox()
        let engine = NativeEngine(finalizer: ParakeetFinalizer())
        engine.onEvent = { inbox.add($0) }
        var ok = true
        func check(_ c: Bool, _ what: String) { say((c ? "ok   " : "FAIL ") + what); if !c { ok = false } }
        check(!engine.isReady, "not ready before start")
        let t0 = Date()
        engine.start()
        let first = await inbox.waitReady(count: 1, timeout: 120)
        check(first && engine.isReady, String(format: ".ready after start (%.2f s)", Date().timeIntervalSince(t0)))
        say("capabilities after first ready: \(engine.capabilities.rawValue)")
        engine.stop()
        check(!engine.isReady, "isReady false after stop")
        let t1 = Date()
        engine.start()
        let second = await inbox.waitReady(count: 2, timeout: 120)
        check(second && engine.isReady, String(format: ".ready again after stop+start (%.2f s)", Date().timeIntervalSince(t1)))
        // A session works after the reload.
        let id = engine.beginSession(SessionOptions(language: "", channel: .mic, kind: .dictation))
        engine.push(id, pcm: Data(count: 3_200 * 10))
        engine.end(id)
        let end = Date().addingTimeInterval(20)
        var gotFinal = false
        while Date() < end, !gotFinal {
            gotFinal = inbox.all().contains { if case .final(let sid, _, _, _, _, _) = $0.1 { return sid == id } else { return false } }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        check(gotFinal, "a session ends with a final after the reload")
        engine.stop()
        return ok ? 0 : 1
    }

    // MARK: unload

    private static func unload() async -> Int32 {
        let hub = ModelHub.shared
        guard hub.gemmaAvailable() else { say("Gemma not downloaded"); return 2 }
        let inbox = Inbox()
        let engine = NativeEngine(finalizer: nil)
        engine.onEvent = { inbox.add($0) }
        say("start: \(mem())")
        func waitFor(_ match: @escaping (EngineEvent) -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(180)
            while Date() < end {
                if inbox.all().contains(where: { match($0.1) }) { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        engine.polish(id: 1, text: "so um we should meet on thursday at three", before: "")
        guard await waitFor({ if case .polished(1, _) = $0 { return true } else { return false } }) else { say("polish timed out"); return 1 }
        engine.summarize(id: 2, transcript: "You: We will ship the Kestrel report on Friday.\nThem: Good, I will send the budget table by Thursday.\n", tags: ["meeting"])
        guard await waitFor({ if case .summary(2, _) = $0 { return true } else { return false } }) else { say("summary timed out"); return 1 }
        do {  // the sweep's LLM wrapper, as VaultSweeper makes it: one per run, dropped afterwards
            let llm = GemmaVaultLLM(control: SweepControl())
            _ = try await llm.ask("Answer in one word.", "Say hello.", maxTokens: 8)
        } catch { say("sweep llm failed: \(error)"); return 1 }
        let loaded = (MLX.Memory.activeMemory, MLX.Memory.cacheMemory)
        say("after polish + summary + sweep call: \(mem())")
        await hub.unload(.gemma)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = (MLX.Memory.activeMemory, MLX.Memory.cacheMemory)
        say("after unload(.gemma): \(mem())")
        let freed = Double(loaded.0 + loaded.1 - after.0 - after.1) / 1_048_576
        say(String(format: "freed %.0f MB of %.0f MB (isLoaded=%d)", freed, Double(loaded.0 + loaded.1) / 1_048_576, hub.isLoaded(.gemma) ? 1 : 0))
        // Reload works afterwards.
        engine.polish(id: 3, text: "and then we go home", before: "")
        let again = await waitFor({ if case .polished(3, _) = $0 { return true } else { return false } })
        say("polish after unload: \(again ? "ok" : "timed out"), \(mem())")
        let pass = freed > 0.8 * Double(loaded.0 + loaded.1) / 1_048_576 && again
        say(pass ? "PASS" : "FAIL")
        return pass ? 0 : 1
    }

    // MARK: dictation

    private struct Clip: Decodable { let id: String; let wav: String; let lang: String?; let dataset: String?; let kind: String? }
    private struct Row: Encodable {
        let id: String; let dataset: String; let lang: String; let seconds: Double
        let raw: String; let text: String; let detected: String; let ms: Int; let partials: Int
    }

    private static func dictation(_ a: [String]) async -> Int32 {
        let manifest = URL(fileURLWithPath: a[1]), out = URL(fileURLWithPath: a[2])
        let per = a.count > 3 ? Int(a[3]) ?? 10 : 10
        do {
            let all = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
            var clips: [Clip] = []
            for ds in ["fleurs", "voxpopuli"] {
                for lang in ["de", "en"] {
                    clips += all.filter { $0.dataset == ds && $0.lang == lang && $0.kind == "clip" }.prefix(per)
                }
            }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let inbox = Inbox()
            let engine = NativeEngine(finalizer: ParakeetFinalizer())
            engine.onEvent = { inbox.add($0) }
            let t0 = Date()
            engine.start()
            guard await inbox.waitReady(count: 1, timeout: 300) else { say("engine never became ready"); return 1 }
            say(String(format: "ready after %.1f s; %d clips, paced in real time", Date().timeIntervalSince(t0), clips.count))
            let conv = AudioConverter()
            let base = manifest.deletingLastPathComponent()
            let enc = JSONEncoder(); enc.outputFormatting = .withoutEscapingSlashes
            var lines = Data()
            var latencies: [Double] = []
            for (i, c) in clips.enumerated() {
                let pcm = try conv.resampleAudioFile(base.appendingPathComponent(c.wav))
                var int16 = pcm.map { Int16(max(-1, min(1, $0)) * 32_767) }
                int16 += [Int16](repeating: 0, count: 4_800)  // the app keeps the mic open 0.3 s after release
                inbox.clear()
                let id = engine.beginSession(SessionOptions(language: "", channel: .mic, kind: .dictation))
                let step = 1_600  // 100 ms
                let start = Date()
                for (n, s) in stride(from: 0, to: int16.count, by: step).enumerated() {
                    let wake = start.addingTimeInterval(Double(n) * 0.1)
                    let wait = wake.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                    var chunk = Array(int16[s..<min(s + step, int16.count)])
                    if chunk.count < step { chunk += [Int16](repeating: 0, count: step - chunk.count) }
                    engine.push(id, pcm: chunk.withUnsafeBufferPointer { Data(buffer: $0) })
                }
                let released = Date()
                engine.end(id)
                var final: (Date, String, String?)?
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline, final == nil {
                    for (when, e) in inbox.all() {
                        if case .final(let sid, _, let text, let lang, _, _) = e, sid == id { final = (when, text, lang) }
                    }
                    if final == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
                }
                guard let f = final else { say("\(c.id): no final in 60 s"); continue }
                let partials = inbox.all().filter { if case .partial = $0.1 { return true } else { return false } }.count
                let ms = Int(f.0.timeIntervalSince(released) * 1000)
                latencies.append(Double(ms))
                // What the app inserts: DictationFlow.clean on the engine's final.
                let text = DictationFlow.clean(f.1, lang: f.2)
                lines += try enc.encode(Row(id: c.id, dataset: c.dataset ?? "", lang: c.lang ?? "", seconds: Double(pcm.count) / 16_000,
                                            raw: f.1, text: text, detected: f.2 ?? "", ms: ms, partials: partials)) + Data("\n".utf8)
                say("\(i + 1)/\(clips.count) \(c.id) \(ms) ms | \(text.prefix(60))")
            }
            try lines.write(to: out.appendingPathComponent("e2e-dictation.jsonl"))
            let s = latencies.sorted()
            if !s.isEmpty {
                say(String(format: "release-to-text (provisional): first clip %.0f ms, median %.0f ms, p90 %.0f ms, max %.0f ms, n=%d",
                           latencies[0], s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))], s.last!, s.count))
            }
            say("footprint: \(mem())")
            engine.stop()
            return 0
        } catch { say("error: \(error)"); return 1 }
    }
}
