import CryptoKit
import Foundation

// Unit G tests. `selfTest()` is model-free and offline (URLProtocol stub, sparse files in a temp root);
// `--enginetest-store gemma` is the one real end-to-end: a temp root holding a copy of the existing Gemma snapshot,
// one Gemma load through ModelHub (MLX reading the metallib from that root when present).

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
        guard args.first == "gemma" else {
            FileHandle.standardError.write(Data("usage: --enginetest-store gemma [SNAPSHOT_DIR]\n".utf8)); return 2
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
        if let m = ProcessInfo.processInfo.environment["IONIAN_FLOW_TEST_METALLIB"] {  // a metallib to place in the temp root
            try? fm.createDirectory(at: ModelStore.metallibURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: URL(fileURLWithPath: m), to: ModelStore.metallibURL)
        }
        print("temp root: \(tmp.path)")
        print(ModelStore.shared.isInstalled(.cleanup) ? "ok   cleanup installed in temp root" : "FAIL cleanup not installed")
        print("metallib in root: \(fm.fileExists(atPath: ModelStore.metallibURL.path))")
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

    private static func newestSnapshot() -> URL? {
        let snaps = fm().homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots")
        return (try? fm().contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil))?.first
    }
    private static func fm() -> FileManager { .default }
}
