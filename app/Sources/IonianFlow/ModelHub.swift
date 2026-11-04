import FluidAudio
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// Unit D (ModelHub). The single owner of every model in the process (24 GB machine, one process):
// lazy loads, one serial lane for Parakeet/CTC/Gemma work, unload policy, memory sampling.
// Callers: B (nemotron), C (parakeet), E and F (gemma, serial). Models live in ModelStore.root
// (downloaded by ModelStore; IONIAN_FLOW_DEV_HF_CACHE=1 reads the Python tools' caches instead). Reference:
// scripts/coexist-bench main.swift (Serial actor, loaders); the n-1 prefill rule lives with the caller, in Polisher.
//
// Contract:
//  - Every loader is idempotent and concurrency-safe: concurrent callers share one load.
//  - Models are returned warmed up (one second of silence through Nemotron/Parakeet, as in coexist-bench).
//  - The two Nemotron managers are NOT serialized: each belongs to one live stream and is fed by one task.
//  - Parakeet, CTC and Gemma work must go through `serial`, so a final pass and a polish never overlap.
//    `serial` is FIFO and NOT reentrant: a job that awaits other jobs on the same hub deadlocks.
//  - Loaders throw EngineError.modelMissing(name) when the cache is empty (no download in Phase 1).

enum HubModel: Sendable, CaseIterable { case nemotronMic, nemotronSystem, parakeet, gemma }

/// Parakeet TDT Ultra plus the CTC vocabulary model. The VocabularyBoostingSession is built from `ctc` and the
/// vocabulary by Unit C, not by the hub.
struct ParakeetModels {
    let asr: AsrManager
    let ctc: CtcModels
}

actor ModelHub {
    static let shared = ModelHub()

    init() {}

    // One in-flight/finished load Task per model; concurrent callers await the same Task (no double load).
    private var nemotronTasks: [Channel: Task<StreamingNemotronMultilingualAsrManager, Error>] = [:]
    private var parakeetTask: Task<ParakeetModels, Error>?
    private var gemmaTask: Task<ModelContainer, Error>?
    private var vadManager: VadManager?
    private var loadedSet: Set<HubModel> = []
    /// How many times each model really loaded (test hook: must stay at 1 without an unload in between).
    private(set) var loadCounts: [HubModel: Int] = [:]
    /// Wall seconds of the last load per model (test/log hook).
    private(set) var loadSeconds: [HubModel: Double] = [:]

    private func record(_ m: HubModel, _ t0: Date) {
        loadedSet.insert(m)
        loadCounts[m, default: 0] += 1
        loadSeconds[m] = Date().timeIntervalSince(t0)
    }

    /// Nemotron multilingual streaming manager for one channel (560 ms chunks, Latin ship), loaded lazily.
    /// The logits step decoder that vocabulary biasing needs is loaded by FluidAudio on the first
    /// `setCustomVocabulary` call (it is skipped by default to save memory).
    func nemotron(_ channel: Channel) async throws -> StreamingNemotronMultilingualAsrManager {
        if let t = nemotronTasks[channel] { return try await t.value }
        let which: HubModel = channel == .mic ? .nemotronMic : .nemotronSystem
        let t = Task { () -> StreamingNemotronMultilingualAsrManager in
            let t0 = Date()
            let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: ModelStore.nemotronLanguage, chunkMs: ModelStore.nemotronChunkMs,
                to: ModelStore.devCaches ? nil : ModelStore.speechDirectory)
            let m = StreamingNemotronMultilingualAsrManager()
            try await m.loadModels(from: dir)
            _ = try await m.process(samples: [Float](repeating: 0, count: 16000))
            _ = try await m.finish()
            await m.reset()
            self.record(which, t0)
            return m
        }
        nemotronTasks[channel] = t
        do { return try await t.value } catch { if nemotronTasks[channel] != nil { nemotronTasks[channel] = nil }; throw error }
    }

    /// Parakeet Ultra + CTC (ctc110m), ONE shared instance, loaded lazily.
    func parakeet() async throws -> ParakeetModels {
        if let t = parakeetTask { return try await t.value }
        let t = Task { () -> ParakeetModels in
            let t0 = Date()
            let models = try await AsrModels.downloadAndLoad(to: ModelStore.devCaches ? nil : ModelStore.parakeetDirectory, version: .ultra)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            var warm = TdtDecoderState.make()
            _ = try await asr.transcribe([Float](repeating: 0, count: 16000), decoderState: &warm)
            let ctc = try await CtcModels.downloadAndLoad(to: ModelStore.devCaches ? nil : ModelStore.ctcDirectory, variant: .ctc110m)
            self.record(.parakeet, t0)
            return ParakeetModels(asr: asr, ctc: ctc)
        }
        parakeetTask = t
        do { return try await t.value } catch { parakeetTask = nil; throw error }
    }

    /// Silero VAD for the transcription segmenter, loaded lazily and shared by both channels (each keeps its own
    /// stream state). Small (a few MB); `nil` if it can't be loaded: the segmenter then uses its energy gate.
    func vad() async -> VadManager? {
        if let m = vadManager { return m }
        do {
            let m = ModelStore.devCaches
                ? try await VadManager(config: VadConfig(defaultThreshold: 0.5))
                : try await VadManager(config: VadConfig(defaultThreshold: 0.5), modelDirectory: ModelStore.vadDirectory)
            vadManager = m
            return m
        } catch {
            NSLog("Ionian Flow: VAD unavailable, segmenting by energy: %@", error.localizedDescription)
            return nil
        }
    }

    /// Gemma 4 E2B (4 bit), loaded lazily. Throws .modelMissing("gemma") when not downloaded.
    func gemma() async throws -> ModelContainer {
        if let t = gemmaTask { return try await t.value }
        guard let dir = Self.gemmaDirectory() else { throw EngineError.modelMissing("gemma") }
        let t = Task { () -> ModelContainer in
            let t0 = Date()
            ModelStore.activateMetallib()
            let c = try await LLMModelFactory.shared.loadContainer(from: dir, using: #huggingFaceTokenizerLoader())
            self.record(.gemma, t0)
            return c
        }
        gemmaTask = t
        do { return try await t.value } catch { gemmaTask = nil; throw error }
    }

    /// Our own Gemma copy (ModelStore.root) when complete; otherwise, only with IONIAN_FLOW_DEV_HF_CACHE=1, the newest
    /// complete snapshot in the Hugging Face cache that Python tools left behind.
    private nonisolated static func gemmaDirectory() -> URL? {
        if ModelStore.filesInstalled(ModelStore.gemmaFiles, at: ModelStore.gemmaDirectory) { return ModelStore.gemmaDirectory }
        return ModelStore.devCaches ? devGemmaDirectory() : nil
    }

    private nonisolated static func devGemmaDirectory() -> URL? {
        let home = ProcessInfo.processInfo.environment["HF_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface")
        let snaps = home.appendingPathComponent("hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: snaps, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let fm = FileManager.default
        return dirs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.first { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: $0.appendingPathComponent("model.safetensors").path) }
    }

    /// True when the cleanup model is on disk (drives EngineCapabilities.polish/.summary). Cheap, no load.
    nonisolated func gemmaAvailable() -> Bool { Self.gemmaDirectory() != nil }

    func isLoaded(_ m: HubModel) -> Bool { loadedSet.contains(m) }

    /// Drop a model from memory (the next accessor reloads it). Callers that still hold the instance keep it
    /// alive until they let go, so drop your references first. Gemma also clears MLX's buffer cache.
    ///
    /// Unload policy (deliberately simple): the hub never unloads on its own. The owner of each model decides:
    ///  - Gemma (~3 GB with the GPU cache) is the one worth dropping: call `unload(.gemma)` when no
    ///    polish/summary/sweep job has run for a while (suggested 10 min idle) or on memory pressure
    ///    (see `onMemoryPressure`). The reload costs a few seconds.
    ///  - Nemotron managers are dropped when their session ends only if the app wants the memory back.
    ///  - Parakeet is shared by dictation and the final pass; keep it unless under critical pressure.
    func unload(_ m: HubModel) async {
        switch m {
        case .nemotronMic: nemotronTasks[.mic] = nil
        case .nemotronSystem: nemotronTasks[.system] = nil
        case .parakeet: parakeetTask = nil
        case .gemma: gemmaTask = nil
        }
        loadedSet.remove(m)
        if m == .gemma { MLX.Memory.clearCache() }
    }

    private var pressureSource: DispatchSourceMemoryPressure?
    /// Install a system memory-pressure handler: on warning/critical it unloads Gemma (the cheapest to
    /// reload, the largest to hold). Idempotent. Call once at app start if wanted.
    func installMemoryPressureHandler() {
        guard pressureSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        src.setEventHandler { Task { await ModelHub.shared.unload(.gemma) } }
        src.resume()
        pressureSource = src
    }

    /// Physical footprint of the process in MB (TASK_VM_INFO phys_footprint). Core ML weights mostly do not show here.
    nonisolated func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Run `work` alone on the shared model lane: one job at a time, held across awaits. Jobs of the same
    /// priority run in submission order; a `.high` job (a transcript final, a dictation final) always goes
    /// before every waiting `.low` job (polish, summary, vault sweep), so cleanup never delays the text.
    nonisolated func serial<T>(_ priority: LanePriority = .high, label: String = "job", _ work: () async throws -> T) async rethrows -> T {
        let queued = Date()
        await gate.acquire(priority)
        let started = Date()
        defer { gate.release(); LaneLog.record(label, priority, queued: queued, started: started, depth: gate.waiting) }
        return try await work()
    }

    private nonisolated let gate = SerialGate()
}

enum LanePriority: Int, Sendable { case high = 0, low = 1 }

/// Optional per-job timing for the shared lane: with IONIAN_LANE_LOG=<file>, one CSV line per finished job
/// (finish time, label, priority, wait ms, run ms, jobs still waiting). Off otherwise.
enum LaneLog {
    private static let t0 = Date()
    private static let lock = NSLock()
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["IONIAN_LANE_LOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: Data("t,label,priority,wait_ms,run_ms,waiting\n".utf8))
        return FileHandle(forWritingAtPath: path)
    }()

    static func record(_ label: String, _ p: LanePriority, queued: Date, started: Date, depth: Int) {
        guard let handle else { return }
        let now = Date()
        let line = String(format: "%.3f,%@,%@,%.0f,%.0f,%d\n", now.timeIntervalSince(t0), label, p == .high ? "high" : "low",
                          started.timeIntervalSince(queued) * 1000, now.timeIntervalSince(started) * 1000, depth)
        lock.lock(); defer { lock.unlock() }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
    }
}

/// Async mutex behind ModelHub.serial (an actor alone would interleave at every await): FIFO within a priority,
/// high before low.
final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [[CheckedContinuation<Void, Never>]] = [[], []]

    /// Jobs queued right now.
    var waiting: Int { lock.lock(); defer { lock.unlock() }; return waiters[0].count + waiters[1].count }

    func acquire(_ priority: LanePriority = .high) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy { waiters[priority.rawValue].append(c); lock.unlock() } else { busy = true; lock.unlock(); c.resume() }
        }
    }

    func release() {
        lock.lock()
        let q = waiters[0].isEmpty ? 1 : 0
        if waiters[q].isEmpty { busy = false; lock.unlock() } else { let next = waiters[q].removeFirst(); lock.unlock(); next.resume() }
    }
}
