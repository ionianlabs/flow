import FluidAudio
import Foundation
import MLX
import MLXLMCommon

// Unit D. The heavy hub test
// (--enginetest-hub: loads every model, samples memory, exercises unload).
//
//   --enginetest-hub [--minutes N] [--data DIR]      (run under: flock /tmp/ionian-ne-models.lock ...)
// --data defaults to $FLOW_BENCH/data or ../flow-bench/bench/data next to the repo checkout (from #filePath).

enum ModelHubCLI {


    /// `--enginetest-hub ...`. Return the process exit code.
    static func cli(_ args: [String]) -> Int32 {
        var minutes = 2.0
        var data: String?
        var i = 0
        while i < args.count {
            if args[i] == "--minutes", i + 1 < args.count { minutes = Double(args[i + 1]) ?? minutes; i += 2 }
            else if args[i] == "--data", i + 1 < args.count { data = args[i + 1]; i += 2 }
            else { i += 1 }
        }
        let dataDir = URL(fileURLWithPath: data ?? defaultDataDir())
        var rc: Int32 = 1
        let done = DispatchSemaphore(value: 0)
        Task { rc = await HubTest(minutes: minutes, dataDir: dataDir).run(); done.signal() }
        done.wait()
        return rc
    }

    private static func defaultDataDir(_ file: String = #filePath) -> String {
        if let b = ProcessInfo.processInfo.environment["FLOW_BENCH"] { return b + "/data" }
        // <repo>/app/Sources/IonianFlow/Dev/ModelHubCLI.swift -> <repo>/../flow-bench/bench/data
        var u = URL(fileURLWithPath: file)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.deletingLastPathComponent().appendingPathComponent("flow-bench/bench/data").path
    }
}

private struct HubClip: Decodable { let id: String; let dataset: String?; let lang: String; let wav: String; let seconds: Double? }

private final class HubStats: @unchecked Sendable {
    private let lock = NSLock()
    var finishMs: [Double] = [], parakeetMs: [Double] = [], gemmaMs: [Double] = []
    var errors: [String] = []
    func add(_ f: () -> Void) { lock.lock(); f(); lock.unlock() }
}

private struct HubTest {
    let minutes: Double
    let dataDir: URL
    let hub = ModelHub.shared
    let stats = HubStats()

    func say(_ s: String) { print(s); fflush(stdout) }
    func vmstat() -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").filter { $0.contains("free") || $0.contains("active") || $0.contains("wired") || $0.contains("compressor") || $0.contains("Swap") || $0.contains("Pages purgeable") || $0.contains("File-backed") || $0.contains("Anonymous") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")
    }

    func run() async -> Int32 {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { say((ok ? "PASS " : "FAIL ") + what); if !ok { failures.append(what) } }

        // Clips
        var clips: [HubClip] = []
        if let text = try? String(contentsOf: dataDir.appendingPathComponent("manifest.jsonl"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let c = try? JSONDecoder().decode(HubClip.self, from: Data(line.utf8)),
                   c.dataset == "fleurs", c.lang == "de" || c.lang == "en", (5...30).contains(c.seconds ?? 0) { clips.append(c) }
            }
        }
        guard clips.count >= 20 else { say("need FLEURS clips under \(dataDir.path) (set FLOW_BENCH or --data)"); return 2 }

        say("vm_stat start: \(vmstat())")
        let base = hub.footprintMB()
        say(String(format: "footprint at start %.0f MB, gemmaAvailable=%d", base, hub.gemmaAvailable() ? 1 : 0))
        guard hub.gemmaAvailable() else { say("Gemma snapshot missing"); return 2 }

        // Concurrent first calls: each model requested 3x at once, must load once.
        let t0 = Date()
        async let p1 = hub.parakeet(), p2 = hub.parakeet(), p3 = hub.parakeet()
        async let g1: Void = { _ = try await hub.gemma() }(), g2: Void = { _ = try await hub.gemma() }()
        async let m1 = hub.nemotron(.mic), m2 = hub.nemotron(.mic), s1 = hub.nemotron(.system)
        let mic: StreamingNemotronMultilingualAsrManager, sys: StreamingNemotronMultilingualAsrManager
        let pk: ParakeetModels
        var gem: ModelContainer?
        do {
            let (a, b, c) = try await (p1, p2, p3)
            _ = try await (g1, g2)
            let (x, y, z) = try await (m1, m2, s1)
            check(a.asr === b.asr && b.asr === c.asr, "concurrent parakeet() calls share one instance")
            check(x === y, "concurrent nemotron(.mic) calls share one instance")
            pk = a; mic = x; sys = z; gem = try await hub.gemma()
        } catch { say("load failed: \(error)"); return 1 }
        say(String(format: "all loaded in %.1f s (parallel), footprint %.0f MB", Date().timeIntervalSince(t0), hub.footprintMB()))
        for m in HubModel.allCases {
            let n = await hub.loadCounts[m] ?? 0, s = await hub.loadSeconds[m] ?? 0
            say(String(format: "  %@ loaded %dx, %.1f s", "\(m)", n, s))
            check(n == 1, "no double load: \(m)")
            let loaded = await hub.isLoaded(m)
            check(loaded, "isLoaded \(m)")
        }

        // First call after lazy load works.
        let samples0 = (try? AudioConverter().resampleAudioFile(dataDir.appendingPathComponent(clips[0].wav))) ?? []
        do {
            var st = TdtDecoderState.make()
            let r = try await hub.serial { try await pk.asr.transcribe(samples0, decoderState: &st) }
            check(!r.text.isEmpty, "first Parakeet call returns text")
            let g = try await hub.serial { try await Self.polish("so um the build is uh twenty percent faster now", gem!) }
            check(!g.isEmpty, "first Gemma call returns text")
            _ = try await mic.process(samples: Array(samples0.prefix(16000)))
            _ = try await mic.finish(); await mic.reset()
        } catch { check(false, "first calls: \(error)") }

        // Live load: two streams + serialized Parakeet and Gemma work.
        let deadline = Date().addingTimeInterval(minutes * 60)
        let peak = HubPeak()
        let sampler = Task { while !Task.isCancelled { peak.mb = max(peak.mb, hub.footprintMB()); try? await Task.sleep(nanoseconds: 1_000_000_000) } }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await stream("mic", mic, clips: clips, offset: 0, deadline: deadline) }
            group.addTask { await stream("system", sys, clips: clips, offset: 7, deadline: deadline) }
        }
        sampler.cancel()

        func p(_ v: [Double], _ q: Double) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count - 1) * q + 0.5))] }
        var fin: [Double] = [], pkm: [Double] = [], gm: [Double] = [], errs: [String] = []
        stats.add { fin = stats.finishMs; pkm = stats.parakeetMs; gm = stats.gemmaMs; errs = stats.errors }
        say(String(format: "finals %d: nemotron finish p50 %.0f ms p99 %.0f ms max %.0f ms | parakeet n=%d p50 %.0f ms | gemma n=%d p50 %.0f ms",
                   fin.count, p(fin, 0.5), p(fin, 0.99), fin.max() ?? 0, pkm.count, p(pkm, 0.5), gm.count, p(gm, 0.5)))
        check(!fin.isEmpty && (fin.max() ?? .infinity) <= 1000, "Nemotron finals never wait more than 1 s behind live work")
        check(errs.isEmpty, "no errors during run (\(errs.count)) \(errs.prefix(3))")
        let limit = 3080 * 1.1
        say(String(format: "peak footprint %.0f MB (limit %.0f MB)", peak.mb, limit))
        check(peak.mb <= limit, "footprint under Phase 0 peak + 10 %")

        // Unload and reload one model. The test lets go of its container first, as the app does: unload only
        // drops the hub's reference, so a held container would keep the old weights next to the new ones.
        gem = nil
        await hub.unload(.gemma)
        let unloaded = await !hub.isLoaded(.gemma)
        check(unloaded, "unload(.gemma) marks it unloaded")
        if let g = try? await hub.gemma(), let out = try? await hub.serial(.high, label: "job", { try await Self.polish("hello there this is a test", g) }) {
            let n = await hub.loadCounts[.gemma] ?? 0
            check(n == 2 && !out.isEmpty, "gemma reloads after unload and works")
        } else { check(false, "gemma reload") }

        say("vm_stat end: \(vmstat())")
        say(String(format: "footprint end %.0f MB (start %.0f MB)", hub.footprintMB(), base))
        say(failures.isEmpty ? "ALL PASS" : "FAILED: \(failures.joined(separator: "; "))")
        return failures.isEmpty ? 0 : 1
    }

    static func polish(_ text: String, _ llm: ModelContainer) async throws -> String {
        let input = try await llm.prepare(input: UserInput(
            chat: [.system("Fix punctuation, remove filler words. Output one line."), .user("Segment: \(text)\nOutput:")],
            additionalContext: ["enable_thinking": false]))
        var params = GenerateParameters(maxTokens: 60, temperature: 0)
        params.prefill.stepSize = max(1, input.text.tokens.size - 1)
        var out = ""
        for await g in try await llm.generate(input: input, parameters: params) { if let c = g.chunk { out += c } }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Real-time feed (100 ms chunks); at each clip end the Nemotron final is timed, then Parakeet and Gemma
    /// jobs for that clip are queued on the hub's serial lane without waiting.
    func stream(_ name: String, _ m: StreamingNemotronMultilingualAsrManager, clips: [HubClip], offset: Int, deadline: Date) async {
        let conv = AudioConverter()
        var index = offset
        var pending: [Task<Void, Never>] = []
        while Date() < deadline {
            let clip = clips[index % clips.count]; index += 2
            guard let samples = try? conv.resampleAudioFile(dataDir.appendingPathComponent(clip.wav)) else { continue }
            await m.setLanguage(clip.lang == "de" ? "de-DE" : "en-US")
            let t0 = DispatchTime.now().uptimeNanoseconds
            var k = 0
            while k * 1600 < samples.count, Date() < deadline {
                let wait = Double(k + 1) * 0.1 - Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                do { _ = try await m.process(samples: Array(samples[k * 1600..<min(samples.count, (k + 1) * 1600)])) }
                catch { stats.add { stats.errors.append("\(name) process: \(error)") } }
                k += 1
            }
            let t = Date()
            do { _ = try await m.finish() } catch { stats.add { stats.errors.append("\(name) finish: \(error)") } }
            let ms = Date().timeIntervalSince(t) * 1000
            stats.add { stats.finishMs.append(ms) }
            await m.reset()
            pending.append(Task {
                do {
                    let pk = try await hub.parakeet(), g = try await hub.gemma()
                    let t1 = Date()
                    var st = TdtDecoderState.make()
                    let r = try await hub.serial { try await pk.asr.transcribe(samples, decoderState: &st) }
                    stats.add { stats.parakeetMs.append(Date().timeIntervalSince(t1) * 1000) }
                    let t2 = Date()
                    _ = try await hub.serial { try await Self.polish(r.text, g) }
                    stats.add { stats.gemmaMs.append(Date().timeIntervalSince(t2) * 1000) }
                } catch { stats.add { stats.errors.append("\(name) job: \(error)") } }
            })
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        for t in pending { await t.value }
    }
}

private final class HubPeak: @unchecked Sendable { var mb = 0.0 }
