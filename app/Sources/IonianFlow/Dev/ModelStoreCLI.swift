import CryptoKit
import FluidAudio
import Foundation

// Unit G tests. `selfTest()` is model-free and offline (URLProtocol stub, sparse files in a temp root);
// `--enginetest-store gemma` is the one real end-to-end: a temp root holding a copy of the existing Gemma snapshot,
// one Gemma load through ModelHub (MLX using the compiled mlx.metallib, see ModelStore.metallibLocation).


enum ModelStoreCLI {
    private static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }


    // MARK: End to end

    /// `--enginetest-store gemma [SNAPSHOT_DIR]`: temp root + copy of the existing Gemma snapshot (default: newest in
    /// ~/.cache/huggingface) + one Gemma load through ModelHub; prints where MLX read its kernels from.
    static func cli(_ args: [String]) -> Int32 {
        if args.first == "speech" { return speechCLI(Array(args.dropFirst())) }
        guard args.first == "gemma" else {
            FileHandle.standardError.write(Data("usage: --enginetest-store gemma [SNAPSHOT_DIR] | speech [CANCEL_AT_FRACTION]\n".utf8)); return 2
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ionian-store-e2e-\(UUID().uuidString)")
        setenv("IONIAN_FLOW_MODELS", tmp.path, 1)
        unsetenv("IONIAN_FLOW_DEV_HF_CACHE")
        defer { try? fm.removeItem(at: tmp) }
        let snap = args.count > 1 ? URL(fileURLWithPath: args[1]) : newestSnapshot()
        guard let snap else { print("FAIL no Gemma snapshot to copy"); return 1 }
        do {
            try fm.createDirectory(at: ModelStore.gemmaDirectory, withIntermediateDirectories: true)
            for f in ModelStore.gemmaFiles {
                try fm.copyItem(at: snap.appendingPathComponent(f.name).resolvingSymlinksInPath(), to: ModelStore.gemmaDirectory.appendingPathComponent(f.name))
            }
        } catch { print("FAIL copy: \(error)"); return 1 }
        print("temp root: \(tmp.path)")
        print(ModelStore.shared.isInstalled(.cleanup) ? "ok   cleanup installed in temp root" : "FAIL cleanup not installed")
        print("metallib: \(ModelStore.metallibLocation()?.path ?? "none (build it: scripts/build-metallib.sh)")")
        var rc: Int32 = 1
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let t = Date()
                _ = try await ModelHub.shared.gemma()
                print(String(format: "ok   gemma loaded from the temp root in %.1f s", Date().timeIntervalSince(t)))
                rc = 0
            } catch { print("FAIL gemma load: \(error)") }
            done.signal()
        }
        done.wait()
        return rc
    }

    // MARK: Speech end to end (network, about 1.3 GB)

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        private var cancelAt: Double?
        var onCancel: (() -> Void)?
        init(cancelAt: Double?) { self.cancelAt = cancelAt }
        func add(_ p: Double) {
            lock.lock(); values.append(p)
            let fire = cancelAt.map { p >= $0 } ?? false
            if fire { cancelAt = nil }
            lock.unlock()
            if fire { onCancel?() }
        }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// path -> size of every file under `dir` (partials included).
    private static func inventory(_ dir: URL) -> [String: Int64] {
        var out: [String: Int64] = [:]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return out }
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { out[String(u.path.dropFirst(dir.path.count))] = Int64(v?.fileSize ?? 0) }
        }
        return out
    }

    /// `--enginetest-store speech [CANCEL_AT_FRACTION=0.3]`: fresh temp root; download(.speech) with a cancel at the
    /// fraction, resume to the end; progress must be monotonic; then load Nemotron + Parakeet + CTC from that root,
    /// transcribe samples/*.wav (SAMPLES_DIR or ./samples), remove(.speech). Never touches the real model root.
    static func speechCLI(_ args: [String]) -> Int32 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ionian-store-speech-\(UUID().uuidString)")
        setenv("IONIAN_FLOW_MODELS", tmp.path, 1)
        unsetenv("IONIAN_FLOW_DEV_HF_CACHE")
        defer { try? fm.removeItem(at: tmp) }
        let cancelAt = Double(args.first ?? "") ?? 0.3
        let samples = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAMPLES_DIR"] ?? "samples")
        var rc: Int32 = 0
        func check(_ ok: Bool, _ msg: String) { print(ok ? "ok   \(msg)" : "FAIL \(msg)"); if !ok { rc = 1 } }
        func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1e6) }
        func monotonic(_ v: [Double]) -> Bool { zip(v, v.dropFirst()).allSatisfy { $0 <= $1 } && (v.first ?? 0) >= 0 && (v.last ?? 2) <= 1 }
        print("temp root: \(tmp.path)")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let store = ModelStore.shared
            check(!store.isInstalled(.speech), "speech not installed in the fresh root")
            // Run 1: cancel at the fraction.
            let log1 = ProgressLog(cancelAt: cancelAt)
            log1.onCancel = { store.cancel(.speech) }
            let t1 = Date()
            var cancelled = false
            do { try await store.download(.speech, progress: { log1.add($0) }) }
            catch ModelStoreError.cancelled { cancelled = true } catch { print("download 1 error: \(error)") }
            let s1 = String(format: "%.0f s", Date().timeIntervalSince(t1))
            let inv1 = inventory(ModelStore.speechDirectory)
            let kept = inv1.values.reduce(0, +)
            let p1 = log1.all
            check(cancelled, "run 1 cancelled at \(String(format: "%.2f", p1.last ?? 0)) after \(s1)")
            check(monotonic(p1) && p1.count > 3, "run 1 progress monotonic (\(p1.count) updates, last \(String(format: "%.3f", p1.last ?? 0)))")
            check(!store.isInstalled(.speech), "not installed after cancel")
            print("     on disk after cancel: \(mb(kept)) in \(inv1.count) files")
            // Run 2: resume.
            let log2 = ProgressLog(cancelAt: nil)
            let t2 = Date()
            do { try await store.download(.speech, progress: { log2.add($0) }) } catch { check(false, "resume failed: \(error)") }
            let secs2 = Date().timeIntervalSince(t2)
            let inv2 = inventory(ModelStore.speechDirectory)
            let total = inv2.values.reduce(0, +)
            let p2 = log2.all
            check(monotonic(p2) && p2.last == 1, "run 2 progress monotonic to 1 (\(p2.count) updates, first \(String(format: "%.3f", p2.first ?? -1)))")
            check(store.isInstalled(.speech), "installed after resume; \(mb(total)) on disk, resume took \(String(format: "%.0f", secs2)) s")
            // Files complete at cancel (not .partial) must be byte-identical in size afterwards.
            let completed = inv1.filter { !$0.key.contains(".partial") }
            let changed = completed.filter { inv2[$0.key] != $0.value }
            for c in changed { print("     changed: \(c.key) \(c.value) -> \(inv2[c.key].map(String.init) ?? "gone")") }
            let partialBytes = inv1.filter { $0.key.hasSuffix(".partial") }
            print("     partials at cancel: \(partialBytes.map { "\($0.key) \(mb($0.value))" })")
            for (k, _) in partialBytes { let f = String(k.dropLast(8)); print("     partial \(f): final size \(inv2[f].map(mb) ?? "missing")") }
            check(changed.isEmpty, "\(completed.count) files complete at cancel kept their size (\(mb(completed.values.reduce(0, +)))); remaining to fetch \(mb(total - completed.values.reduce(0, +)))")
            // Load and transcribe from the temp root.
            do {
                let t = Date()
                let pk = try await ModelHub.shared.parakeet()
                let mic = try await ModelHub.shared.nemotron(.mic)
                print(String(format: "ok   Nemotron + Parakeet + CTC loaded from the temp root in %.1f s", Date().timeIntervalSince(t)))
                let wavs = ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
                check(!wavs.isEmpty, "found \(wavs.count) wav files in \(samples.path)")
                for w in wavs {
                    let pcm = try AudioConverter().resampleAudioFile(w)
                    var live = ""
                    for k in stride(from: 0, to: pcm.count, by: 8960) { _ = try await mic.process(samples: Array(pcm[k..<min(pcm.count, k + 8960)])) }
                    live = try await mic.finish(); await mic.reset()
                    var st = TdtDecoderState.make()
                    let final = try await pk.asr.transcribe(pcm, decoderState: &st).text
                    print("     \(w.lastPathComponent) live: \(live.prefix(90))")
                    print("     \(w.lastPathComponent) parakeet: \(final.prefix(90))")
                    check(!live.trimmingCharacters(in: .whitespaces).isEmpty && !final.trimmingCharacters(in: .whitespaces).isEmpty, "\(w.lastPathComponent) transcribed by both")
                }
            } catch { check(false, "load or transcribe: \(error)") }
            // Remove.
            await ModelHub.shared.unload(.parakeet)
            do { try store.remove(.speech) } catch { check(false, "remove: \(error)") }
            check(!store.isInstalled(.speech) && !fm.fileExists(atPath: ModelStore.speechDirectory.path), "remove(.speech) leaves nothing, isInstalled false")
            done.signal()
        }
        done.wait()
        return rc
    }

    private static func newestSnapshot() -> URL? {
        let snaps = fm().homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots")
        return (try? fm().contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil))?.first
    }
    private static func fm() -> FileManager { .default }
}
