import AppKit
import FluidAudio
import Foundation
import SwiftUI

/// Dev tools for the dictation overlay, no window ever on screen.
///
/// `IonianFlow --overlay-record WAV OUT.json`: pushes a clip through the live engine in real time, as the app
/// does from the mic, and logs every partial with its time since the key press, plus the mic level every 100 ms.
/// Loads speech models: wrap it in the model lock.
///
/// `IonianFlow --overlay-replay EVENTS.json [--out DIR] [--fps 30] [--dark] [--from S] [--to S] [--cpu]`: drives an
/// OverlayModel with such a log in real time and writes the overlay view offscreen as `frame-00000.png`, ... at
/// fixed times; `--cpu` takes no frames and prints this process's CPU use instead. Real time because SwiftUI's animations run on the wall clock.
enum OverlayReplay {
    struct Log: Codable {
        struct Partial: Codable { var t: Double; var text: String }
        var lang: String?
        /// Seconds from the key press to the release.
        var release: Double
        var partials: [Partial]
        /// Mic RMS every 100 ms, from the key press.
        var levels: [Float]
    }

    // MARK: record

    static func record(_ args: [String]) -> Int32 {
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: --overlay-record WAV OUT.json (IONIAN_FLOW_TEST_DIR set)\n".utf8))
            return 2
        }
        Settings.registerDefaults()
        let wav = URL(fileURLWithPath: args[0]), out = URL(fileURLWithPath: args[1])
        Task.detached {
            exit(await runRecord(wav: wav, out: out))
        }
        dispatchMain()
    }

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(Date, EngineEvent)] = []
        func add(_ e: EngineEvent) { lock.lock(); events.append((Date(), e)); lock.unlock() }
        func all() -> [(Date, EngineEvent)] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private static func runRecord(wav: URL, out: URL) async -> Int32 {
        let inbox = Inbox()
        let engine = NativeEngine(finalizer: nil)
        engine.onEvent = { inbox.add($0) }
        engine.start()
        var waited = 0.0
        while !engine.isReady, waited < 300 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 0.05 }
        guard engine.isReady else { print("engine never became ready"); return 1 }
        do {
            let pcm = try AudioConverter().resampleAudioFile(wav)
            // A person starts talking a beat after the key press; the app keeps the mic open 0.3 s after release.
            let lead = [Float](repeating: 0, count: 6_400), tail = [Float](repeating: 0, count: 4_800)
            let samples = lead + pcm + tail
            let step = 1_600  // 100 ms
            let id = engine.beginSession(SessionOptions(language: "", channel: .mic, kind: .dictation))
            let start = Date()
            var levels: [Float] = []
            for (n, s) in stride(from: 0, to: samples.count, by: step).enumerated() {
                let wait = start.addingTimeInterval(Double(n) * 0.1).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                var chunk = Array(samples[s..<min(s + step, samples.count)])
                if chunk.count < step { chunk += [Float](repeating: 0, count: step - chunk.count) }
                levels.append(sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(step)))
                let int16 = chunk.map { Int16(max(-1, min(1, $0)) * 32_767) }
                engine.push(id, pcm: int16.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            let release = Date().timeIntervalSince(start)
            engine.end(id)
            var lang: String?
            var gotFinal = false
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, !gotFinal {
                for (_, e) in inbox.all() { if case .final = e { gotFinal = true } }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            var partials: [Log.Partial] = []
            for (when, e) in inbox.all() {
                guard case .partial(let sid, _, let text, let l) = e, sid == id else { continue }
                if let l { lang = l }
                partials.append(Log.Partial(t: when.timeIntervalSince(start), text: DictationFlow.clean(text, lang: l ?? lang)))
            }
            let log = Log(lang: lang, release: release, partials: partials, levels: levels)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(log).write(to: out)
            print("wrote \(out.path): \(partials.count) partials, first at \(partials.first.map { String(format: "%.2f s", $0.t) } ?? "-")")
            engine.stop()
            return 0
        } catch {
            print("record failed: \(error)")
            return 1
        }
    }

    // MARK: replay

    @MainActor static func replay(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let path = args.first(where: { !$0.hasPrefix("--") }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let log = try? JSONDecoder().decode(Log.self, from: data)
        else {
            print("usage: --overlay-replay EVENTS.json [--out DIR] [--fps 30] [--dark] [--from S] [--to S]")
            return 2
        }
        let dir = URL(fileURLWithPath: value("--out") ?? "overlay-frames")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fps = Double(value("--fps") ?? "") ?? 30
        let from = Double(value("--from") ?? "") ?? 0
        let to = Double(value("--to") ?? "") ?? (log.release + 1.4)

        IonianFont.register()
        let model = OverlayModel()
        let surface = Renderer.Surface(size: CGSize(width: 720, height: 220), backdrop: true, make: { AnyView(OverlayView(model: model)) })
        let canvas = Renderer.Canvas(surface, dark: args.contains("--dark"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // The key press: the pill appears, the mic starts. Levels get the app's own smoothing.
        model.reset()
        model.visible = true
        var smooth: Float = 0
        var nextPartial = 0, nextLevel = 0, frame = 0
        var finished = false
        let clock = Date()
        var t = 0.0
        while t <= to {
            // Feed everything due by now, in order, as the app's callbacks would.
            while nextLevel < log.levels.count, Double(nextLevel) * 0.1 <= t {
                smooth = 0.5 * smooth + 0.5 * log.levels[nextLevel]
                model.level = smooth
                nextLevel += 1
            }
            while nextPartial < log.partials.count, log.partials[nextPartial].t <= t {
                model.update(log.partials[nextPartial].text)
                if let l = log.lang { model.lang = l }
                nextPartial += 1
            }
            if !finished, t >= log.release { model.finishing = true; finished = true }
            if t >= from, !args.contains("--cpu") {
                canvas.snapshot(to: dir.appendingPathComponent(String(format: "frame-%05d.png", frame)))
                frame += 1
            }
            // Next frame time on the wall clock; the run loop keeps SwiftUI animating meanwhile.
            let next = Double(Int((t - from) * fps + 1.5)) / fps + from
            let wait = clock.addingTimeInterval(next).timeIntervalSinceNow
            RunLoop.current.run(until: Date().addingTimeInterval(max(0.001, wait)))
            t = Date().timeIntervalSince(clock)
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let cpu = secs(usage.ru_utime) + secs(usage.ru_stime)
        if args.contains("--cpu") {
            print(String(format: "cpu %.2f s over %.1f s: %.1f %% of one core", cpu, t, 100 * cpu / t))
        } else {
            print("wrote \(frame) frames to \(dir.path)")
        }
        return 0
    }
}
