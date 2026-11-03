import CryptoKit
import FluidAudio
import Foundation
import MLX

// Phase 4: what the app downloads on first launch, and where it keeps it.
//
// Interface contract: the setup guide and Settings (unit H) code against `ModelItem`, `ModelStoreError` and the
// public members of `ModelStore`.
//  - Everything lives under `ModelStore.root` (~/Library/Application Support/Ionian Flow/Models), offline after
//    the first run. Nothing is hosted by us: speech models come from FluidAudio's Hugging Face repos, Gemma from
//    mlx-community on Hugging Face, mlx.metallib from the MLX build (see activateMetallib).
//  - `.speech` is required (Nemotron live, Parakeet final, CTC vocabulary). `.cleanup` is optional (Gemma 4 E2B
//    plus mlx.metallib): skipping it turns cleanup, summaries and LLM vault extraction off; the sweep runs rules only.
//  - Downloads are resumable and idempotent: calling `download` for an installed item returns at once.
//  - Developer switches: IONIAN_FLOW_MODELS overrides the root; IONIAN_FLOW_DEV_HF_CACHE=1 makes ModelHub read the
//    Hugging Face / FluidAudio caches that Python tools left behind. Release builds never set either.

enum ModelItem: String, CaseIterable, Sendable {
    case speech
    case cleanup
}

enum ModelStoreError: Error, Sendable {
    case cancelled
    case network(String)
    case checksum(String)  // a file did not match its pinned sha256
    case disk(String)
}

/// One file of a download: pinned size and sha256.
struct ModelFile: Sendable {
    let name: String
    let url: URL
    let size: Int64
    let sha256: String
}

/// Stop flag shared between `ModelStore.cancel` and the running transfer.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var task: URLSessionTask?
    private var onCancel: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func attach(_ t: URLSessionTask?) {
        lock.lock(); task = t; let c = flag; lock.unlock()
        if c { t?.cancel() }
    }
    func setOnCancel(_ f: (() -> Void)?) { lock.lock(); onCancel = f; lock.unlock() }
    func cancel() {
        lock.lock(); flag = true; let t = task; let f = onCancel; lock.unlock()
        t?.cancel(); f?()
    }
}

/// Resumable HTTP download of one file: `<dest>.partial` is appended to with `Range: bytes=N-`, checked against
/// the pinned size and sha256, then renamed to `dest`. A cancelled or failed transfer keeps the partial file.
final class ResumableFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: ModelFile
    private let dest: URL
    private let cancelFlag: CancelFlag
    private let onBytes: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReport = Date.distantPast
    private var cont: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(file: ModelFile, dest: URL, cancel: CancelFlag, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.file = file; self.dest = dest; self.cancelFlag = cancel; self.onBytes = onBytes
    }

    /// Test hook: session configuration (URLProtocol stubs).
    nonisolated(unsafe) static var configuration: () -> URLSessionConfiguration = { .ephemeral }

    private var partial: URL { dest.appendingPathExtension("partial") }

    func run() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let s = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int64, s == file.size {
            onBytes(file.size); return
        }
        var have = ((try? fm.attributesOfItem(atPath: partial.path))?[.size] as? Int64) ?? 0
        if have > file.size { try? fm.removeItem(at: partial); have = 0 }
        if have < file.size { try await transfer(from: have) } else { onBytes(file.size) }
        if cancelFlag.isCancelled { throw ModelStoreError.cancelled }
        guard Self.sha256(of: partial) == file.sha256 else {
            try? fm.removeItem(at: partial)
            throw ModelStoreError.checksum(file.name)
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: partial, to: dest)
    }

    private func transfer(from offset: Int64) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        do { handle = try FileHandle(forWritingTo: partial) } catch { throw ModelStoreError.disk("\(error)") }
        defer { try? handle?.close(); handle = nil }
        written = offset
        _ = try? handle?.seekToEnd()
        var req = URLRequest(url: file.url)
        req.timeoutInterval = 60
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: req)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cont = c
            cancelFlag.attach(task)
            task.resume()
        }
        cancelFlag.attach(nil)
        onBytes(written)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, written > 0 {  // the server ignored the Range header: start over
            try? handle?.truncate(atOffset: 0); try? handle?.seek(toOffset: 0); written = 0
        } else if code != 200 && code != 206 {
            failure = ModelStoreError.network("HTTP \(code) for \(file.name)")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch {
            failure = ModelStoreError.disk("\(error)"); dataTask.cancel(); return
        }
        written += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.1 { lastReport = Date(); onBytes(written) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = cont; cont = nil
        if cancelFlag.isCancelled { c?.resume(throwing: ModelStoreError.cancelled); return }
        if let f = failure { c?.resume(throwing: f); return }
        if let e = error { c?.resume(throwing: ModelStoreError.network(e.localizedDescription)); return }
        c?.resume()
    }

    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try? h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class ModelStore: @unchecked Sendable {
    static let shared = ModelStore()

    /// ~/Library/Application Support/Ionian Flow/Models (IONIAN_FLOW_MODELS overrides it, for tests).
    static var root: URL {
        if let o = ProcessInfo.processInfo.environment["IONIAN_FLOW_MODELS"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ionian Flow/Models", isDirectory: true)
    }

    /// Developer escape hatch: read the caches Python tools left behind instead of our own root.
    static var devCaches: Bool { ProcessInfo.processInfo.environment["IONIAN_FLOW_DEV_HF_CACHE"] == "1" }

    // MARK: Layout

    /// FluidAudio's `to:` base directory; it adds its own repo folder names below it.
    static var speechDirectory: URL { root.appendingPathComponent("speech", isDirectory: true) }
    static let nemotronLanguage = "de", nemotronChunkMs = 560
    static var nemotronVariantDirectory: URL {
        speechDirectory.appendingPathComponent("nemotron-multilingual")
            .appendingPathComponent(StreamingNemotronMultilingualAsrManager.languageDirectory(for: nemotronLanguage))
            .appendingPathComponent("\(nemotronChunkMs)ms")
    }
    static var parakeetDirectory: URL {
        speechDirectory.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .ultra).lastPathComponent)
    }
    static var ctcDirectory: URL {
        speechDirectory.appendingPathComponent(CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent)
    }
    /// Silero VAD for transcription segments: VadManager's base directory (it adds Models/silero-vad-coreml).
    static var vadDirectory: URL { speechDirectory.appendingPathComponent("vad", isDirectory: true) }
    static var vadModelDirectory: URL {
        vadDirectory.appendingPathComponent("Models/silero-vad-coreml/\(ModelNames.VAD.sileroVadFile)", isDirectory: true)
    }
    static var gemmaDirectory: URL { root.appendingPathComponent("gemma-4-e2b-it-4bit", isDirectory: true) }
    /// Where MLX's Metal kernels live (see `activateMetallib`).
    static var metallibURL: URL { root.appendingPathComponent("mlx/mlx.metallib") }

    /// mlx-community/gemma-4-e2b-it-4bit at a pinned revision (Gemma terms; see ThirdPartyNotices.md).
    static let gemmaRevision = "238767527555cb75a05732a84dff5d6ba0dd6809"
    static let gemmaFiles: [ModelFile] = {
        func f(_ n: String, _ size: Int64, _ sha: String) -> ModelFile {
            ModelFile(name: n, url: URL(string: "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/resolve/\(gemmaRevision)/\(n)")!, size: size, sha256: sha)
        }
        return [
            f("config.json", 6395, "6397cb6eca41b911d1dcab74e17941351057bd759284052a2331918ff6f9246c"),
            f("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
            f("processor_config.json", 1316, "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37"),
            f("tokenizer_config.json", 2740, "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656"),
            f("chat_template.jinja", 17336, "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082"),
            f("model.safetensors.index.json", 218323, "edb157dbf495e23f37377af4a628a9ad13c4ee7937f93ccb36ec9e9a19940f16"),
            f("tokenizer.json", 32_169_626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            f("model.safetensors", 3_550_670_554, "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e"),
        ]
    }()

    /// Approximate sizes of FluidAudio's downloads (measured on disk): Nemotron de/560 ms, Parakeet Ultra, CTC 110m.
    private static let speechParts: [Int64] = [611_000_000, 632_000_000, 103_000_000, 2_000_000]

    private let lock = NSLock()
    private var flags: [ModelItem: CancelFlag] = [:]

    // MARK: Interface

    /// True when every file of the item is on disk and complete. Cheap, no network, no model load.
    func isInstalled(_ item: ModelItem) -> Bool {
        switch item {
        case .speech: return Self.speechInstalled()
        case .cleanup: return Self.filesInstalled(Self.gemmaFiles, at: Self.gemmaDirectory)
        }
    }

    /// Every file present with exactly its pinned size (a `.partial` never counts).
    static func filesInstalled(_ files: [ModelFile], at dir: URL) -> Bool {
        let fm = FileManager.default
        return files.allSatisfy {
            ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent($0.name).path))?[.size] as? Int64) == $0.size
        }
    }

    private static func speechInstalled() -> Bool {
        let fm = FileManager.default
        let v = nemotronVariantDirectory
        let nemotron = ["preprocessor.mlmodelc", "encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc", "tokenizer.json", "metadata.json"]
            .allSatisfy { fm.fileExists(atPath: v.appendingPathComponent($0).path) }
        return nemotron
            && AsrModels.modelsExist(at: parakeetDirectory, version: .ultra)
            && CtcModels.modelsExist(at: ctcDirectory)
            && FileManager.default.fileExists(atPath: vadModelDirectory.path)
            && !hasPartial(speechDirectory)
    }

    private static func hasPartial(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let u as URL in e where u.pathExtension == "partial" { return true }
        return false
    }

    /// Approximate download size, for the setup guide's "about X GB".
    func approximateBytes(_ item: ModelItem) -> Int64 {
        switch item {
        case .speech: return Self.speechParts.reduce(0, +)
        case .cleanup: return Self.gemmaFiles.reduce(0) { $0 + $1.size }
        }
    }

    /// Downloads what is missing, resuming partial files. `progress` gets 0...1 (any thread, throttled).
    /// Throws ModelStoreError; `.cancelled` after `cancel(item)`.
    func download(_ item: ModelItem, progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled(item) { progress(1); return }
        let flag = CancelFlag()
        lock.lock(); flags[item] = flag; lock.unlock()
        defer { lock.lock(); if flags[item] === flag { flags[item] = nil }; lock.unlock() }
        do {
            switch item {
            case .speech: try await downloadSpeech(flag, progress)
            case .cleanup: try await downloadFiles(Self.gemmaFiles, into: Self.gemmaDirectory, flag, progress)
            }
        } catch {
            if flag.isCancelled || error is CancellationError { throw ModelStoreError.cancelled }
            if let e = error as? ModelStoreError { throw e }
            throw ModelStoreError.network("\(error)")
        }
        progress(1)
    }

    /// Stops a running download of the item; partial files stay for the next resume.
    func cancel(_ item: ModelItem) {
        lock.lock(); let f = flags[item]; lock.unlock()
        f?.cancel()
    }

    /// Deletes the item's files (Settings: "Remove cleanup model").
    func remove(_ item: ModelItem) throws {
        cancel(item)
        let fm = FileManager.default
        let dir = item == .speech ? Self.speechDirectory : Self.gemmaDirectory
        if fm.fileExists(atPath: dir.path) {
            do { try fm.removeItem(at: dir) } catch { throw ModelStoreError.disk("\(error)") }
        }
    }

    // MARK: Downloads

    /// Sequential files into `dir`, progress by bytes. Public to the module so tests can drive any file list.
    func downloadFiles(_ files: [ModelFile], into dir: URL, _ flag: CancelFlag, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(files.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        for file in files {
            if flag.isCancelled { throw ModelStoreError.cancelled }
            let base = done
            let fetch = ResumableFetch(file: file, dest: dir.appendingPathComponent(file.name), cancel: flag) {
                progress(min(1, Double(base + $0) / total))
            }
            try await withTaskCancellationHandler { try await fetch.run() } onCancel: { flag.cancel() }
            done += file.size
        }
    }

    /// FluidAudio fetches its own repos (Hugging Face, resumable) into our root via its `to:` parameter.
    /// Stages are weighted by approximate size; FluidAudio reports per-stage fractions.
    private func downloadSpeech(_ flag: CancelFlag, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        let parts = Self.speechParts.map(Double.init), total = parts.reduce(0, +)
        func stage(_ i: Int) -> @Sendable (DownloadProgress) -> Void {
            let base = parts[..<i].reduce(0, +), part = parts[i]
            return { p in progress(min(1, (base + p.fractionCompleted * part) / total)) }
        }
        let work = Task {
            _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: Self.nemotronLanguage, chunkMs: Self.nemotronChunkMs,
                to: Self.speechDirectory, progressHandler: stage(0))
            _ = try await AsrModels.download(to: Self.parakeetDirectory, version: .ultra, progressHandler: stage(1))
            _ = try await CtcModels.download(to: Self.ctcDirectory, variant: .ctc110m)
            _ = try await VadManager(modelDirectory: Self.vadDirectory)  // downloads (about 2 MB) and loads once
        }
        flag.setOnCancel { work.cancel() }
        defer { flag.setOnCancel(nil) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { flag.cancel() }
        if flag.isCancelled { throw ModelStoreError.cancelled }
    }

    // MARK: MLX Metal kernels

    /// Points MLX at our mlx.metallib (MLX.GPU.metallib, mlx-swift's public override) when it is on disk.
    /// Must run before MLX's first GPU use. Without the file MLX falls back to its own lookup (next to the binary).
    static func activateMetallib() {
        if FileManager.default.fileExists(atPath: metallibURL.path) { GPU.metallib = metallibURL }
    }
}
