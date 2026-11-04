import CryptoKit
import FluidAudio
import Foundation

// Unit G tests. `selfTest()` is model-free and offline (URLProtocol stub, sparse files in a temp root);
// `--enginetest-store gemma` is the one real end-to-end: a temp root holding a copy of the existing Gemma snapshot,
// one Gemma load through ModelHub (MLX using the compiled mlx.metallib, see ModelStore.metallibLocation).

/// In-process HTTP server stand-in: serves `body` for any URL, honours `Range`, optionally slowly.
final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var honourRange = true
    nonisolated(unsafe) static var chunk = 0  // 0: all at once; else bytes per 20 ms tick
    nonisolated(unsafe) static var status = 0  // non-zero: answer this status with no body
    nonisolated(unsafe) static var ranges: [String?] = []
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped = true }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.ranges.append(range)
        let url = request.url!
        if Self.status != 0 {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        var start = 0
        if Self.honourRange, let r = range, r.hasPrefix("bytes="), let n = Int(r.dropFirst(6).dropLast()) { start = n }
        let part = Self.body.subdata(in: start..<Self.body.count)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: start > 0 ? 206 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if Self.chunk == 0 {
            client?.urlProtocol(self, didLoad: part)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var pos = 0
        func tick() {
            if self.stopped { return }
            if pos >= part.count { self.client?.urlProtocolDidFinishLoading(self); return }
            let end = min(part.count, pos + Self.chunk)
            self.client?.urlProtocol(self, didLoad: part.subdata(in: pos..<end))
            pos = end
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02, execute: tick)
        }
        tick()
    }
}

enum ModelStoreTests {
    private static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ what: String) { print((c ? "ok   " : "FAIL ") + "store: " + what); if !c { ok = false } }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ionian-store-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let oldRoot = getenv("IONIAN_FLOW_MODELS").map { String(cString: $0) }
        setenv("IONIAN_FLOW_MODELS", tmp.appendingPathComponent("root").path, 1)
        defer { if let o = oldRoot { setenv("IONIAN_FLOW_MODELS", o, 1) } else { unsetenv("IONIAN_FLOW_MODELS") } }
        let store = ModelStore()

        // isInstalled / remove / approximateBytes (sparse files stand in for the 3.5 GB weights)
        check(ModelStore.root.path.hasSuffix("root"), "IONIAN_FLOW_MODELS overrides the root")
        check(!store.isInstalled(.cleanup), "cleanup not installed on an empty root")
        check(ModelStore.vadModelDirectory == nil, "no VAD model on an empty root")
        // The layout FluidAudio 0.18.2 really writes (found by the first-launch acceptance download).
        let vadBundle = ModelStore.vadDirectory.appendingPathComponent("Models/silero-vad/\(ModelNames.VAD.sileroVadFile)/weights")
        try? fm.createDirectory(at: vadBundle, withIntermediateDirectories: true)
        fm.createFile(atPath: vadBundle.appendingPathComponent("weight.bin").path, contents: Data([1]))
        check(ModelStore.vadModelDirectory != nil, "VAD model found in the folder FluidAudio really writes")
        try? fm.removeItem(at: ModelStore.vadDirectory)
        let dir = ModelStore.gemmaDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ModelStore.gemmaFiles {
            let u = dir.appendingPathComponent(f.name)
            fm.createFile(atPath: u.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: u) { try? h.truncate(atOffset: UInt64(f.size)); try? h.close() }
        }
        check(store.isInstalled(.cleanup), "cleanup installed when every file has its pinned size")
        let big = dir.appendingPathComponent("model.safetensors")
        try? fm.moveItem(at: big, to: big.appendingPathExtension("partial"))
        check(!store.isInstalled(.cleanup), "a .partial file does not count")
        try? fm.moveItem(at: big.appendingPathExtension("partial"), to: big)
        if let h = try? FileHandle(forWritingTo: big) { try? h.truncate(atOffset: 1000); try? h.close() }
        check(!store.isInstalled(.cleanup), "a truncated file does not count")
        check(store.approximateBytes(.cleanup) > 3_500_000_000 && store.approximateBytes(.speech) > 1_000_000_000, "approximate sizes")
        try? store.remove(.cleanup)
        check(!fm.fileExists(atPath: dir.path) && !store.isInstalled(.cleanup), "remove deletes the files")

        // Fetch tests against the stub
        ResumableFetch.configuration = {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [StubServer.self]
            return c
        }
        defer { ResumableFetch.configuration = { .ephemeral } }
        var payload = Data(count: 1_000_000)
        payload.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 8) } }
        StubServer.body = payload
        let good = ModelFile(name: "blob.bin", url: URL(string: "https://example.invalid/blob.bin")!, size: Int64(payload.count), sha256: sha(payload))
        let out = tmp.appendingPathComponent("out")

        func run(_ files: [ModelFile], flag: CancelFlag = CancelFlag(), progress: @escaping @Sendable (Double) -> Void = { _ in },
                 whileRunning: (() -> Void)? = nil) -> Result<Void, Error> {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: Result<Void, Error> = .success(())
            Task.detached {
                do { try await store.downloadFiles(files, into: out, flag, progress) } catch { result = .failure(error) }
                done.signal()
            }
            whileRunning?()
            done.wait()
            return result
        }

        // 1. plain download
        StubServer.ranges = []; StubServer.chunk = 0; StubServer.honourRange = true; StubServer.status = 0
        final class Prog: @unchecked Sendable { let l = NSLock(); var v: [Double] = []; func add(_ x: Double) { l.lock(); v.append(x); l.unlock() } }
        let prog = Prog()
        var r = run([good]) { prog.add($0) }
        check((try? r.get()) != nil && fm.contents(atPath: out.appendingPathComponent("blob.bin").path) == payload, "plain download is byte-identical")
        check(prog.v.last == 1 && zip(prog.v, prog.v.dropFirst()).allSatisfy { $0 <= $1 }, "progress is monotone and ends at 1")
        check(!fm.fileExists(atPath: out.appendingPathComponent("blob.bin.partial").path), "no .partial left after success")
        check(StubServer.ranges == [nil], "no Range header on a fresh download")

        // 2. resume from a partial file
        try? fm.removeItem(at: out.appendingPathComponent("blob.bin"))
        try? payload.prefix(400_000).write(to: out.appendingPathComponent("blob.bin.partial"))
        StubServer.ranges = []
        r = run([good])
        check((try? r.get()) != nil && fm.contents(atPath: out.appendingPathComponent("blob.bin").path) == payload, "resumed download is byte-identical")
        check(StubServer.ranges == ["bytes=400000-"], "resume asks for bytes=400000- (got \(StubServer.ranges))")

        // 2b. server ignores Range: restart cleanly
        try? fm.removeItem(at: out.appendingPathComponent("blob.bin"))
        try? payload.prefix(400_000).write(to: out.appendingPathComponent("blob.bin.partial"))
        StubServer.honourRange = false
        r = run([good])
        check((try? r.get()) != nil && fm.contents(atPath: out.appendingPathComponent("blob.bin").path) == payload, "server without Range support: restart, still identical")
        StubServer.honourRange = true

        // 3. sha256 mismatch
        try? fm.removeItem(at: out)
        let bad = ModelFile(name: "bad.bin", url: good.url, size: good.size, sha256: String(repeating: "0", count: 64))
        r = run([bad])
        var isChecksum = false
        if case .failure(let e) = r, case ModelStoreError.checksum = e { isChecksum = true }
        check(isChecksum, "wrong sha256 throws .checksum")
        check(!fm.fileExists(atPath: out.appendingPathComponent("bad.bin").path) && !fm.fileExists(atPath: out.appendingPathComponent("bad.bin.partial").path), "a corrupt file is not kept")

        // 4. HTTP error
        StubServer.status = 404
        r = run([good])
        var isNet = false
        if case .failure(let e) = r, case ModelStoreError.network = e { isNet = true }
        check(isNet, "HTTP 404 throws .network")
        StubServer.status = 0

        // 5. cancel keeps the partial file; the next run resumes
        try? fm.removeItem(at: out)
        StubServer.chunk = 50_000; StubServer.ranges = []
        let flag = CancelFlag()
        r = run([good], flag: flag, whileRunning: { Thread.sleep(forTimeInterval: 0.25); flag.cancel() })
        var isCancel = false
        if case .failure(let e) = r, case ModelStoreError.cancelled = e { isCancel = true }
        let kept = ((try? fm.attributesOfItem(atPath: out.appendingPathComponent("blob.bin.partial").path))?[.size] as? Int64) ?? 0
        check(isCancel, "cancel throws .cancelled")
        check(kept > 0 && kept < Int64(payload.count) && !fm.fileExists(atPath: out.appendingPathComponent("blob.bin").path), "cancel keeps the partial file (\(kept) bytes)")
        StubServer.chunk = 0; StubServer.ranges = []
        r = run([good])
        check((try? r.get()) != nil && fm.contents(atPath: out.appendingPathComponent("blob.bin").path) == payload
              && StubServer.ranges == ["bytes=\(kept)-"], "download after cancel resumes at \(kept)")
        return ok
    }

    // MARK: End to end

    /// `--enginetest-store gemma [SNAPSHOT_DIR]`: temp root + copy of the existing Gemma snapshot (default: newest in
    /// ~/.cache/huggingface) + one Gemma load through ModelHub; prints where MLX read its kernels from.
    static func cli(_ args: [String]) -> Int32 {
        if args.first == "speech" { return speechCLI(Array(args.dropFirst())) }
        if args.first == "download" { return downloadCLI(Array(args.dropFirst())) }
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

    /// `--enginetest-store download [speech] [cleanup]` (default both, in the onboarding order): the real download
    /// into IONIAN_FLOW_MODELS (required, so the user's own root is never used), progress and byte counts printed.
    /// Acceptance test of the built app on a fresh machine; kill it mid-way and run again to see the resume.
    static func downloadCLI(_ args: [String]) -> Int32 {
        guard let root = ProcessInfo.processInfo.environment["IONIAN_FLOW_MODELS"], !root.isEmpty else {
            FileHandle.standardError.write(Data("download needs IONIAN_FLOW_MODELS (an empty temp folder)\n".utf8)); return 2
        }
        print("root: \(root)")
        unsetenv("IONIAN_FLOW_DEV_HF_CACHE")
        let items: [ModelItem] = args.isEmpty ? [.speech, .cleanup] : args.compactMap(ModelItem.init(rawValue:))
        var rc: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for item in items {
                let t = Date()
                let was = ModelStore.shared.isInstalled(item)
                let last = LastPrinted()
                do {
                    try await ModelStore.shared.download(item) { p in
                        if last.shouldPrint(p) { print("\(item.rawValue) \(Int(p * 100)) %"); fflush(stdout) }
                    }
                    let bytes = inventory(item == .speech ? ModelStore.speechDirectory : ModelStore.gemmaDirectory).values.reduce(0, +)
                    let ok = ModelStore.shared.isInstalled(item)
                    print("\(ok ? "ok  " : "FAIL") \(item.rawValue): installed=\(ok) (was \(was)), \(bytes) bytes on disk, \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
                    if !ok { rc = 1 }
                } catch { print("FAIL \(item.rawValue): \(error)"); rc = 1 }
            }
            done.signal()
        }
        done.wait()
        return rc
    }

    private final class LastPrinted: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1.0
        func shouldPrint(_ p: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if p - last >= 0.05 || (p >= 1 && last < 1) { last = p; return true }
            return false
        }
    }

    private static func newestSnapshot() -> URL? {
        let snaps = fm().homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots")
        return (try? fm().contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil))?.first
    }
    private static func fm() -> FileManager { .default }
}
