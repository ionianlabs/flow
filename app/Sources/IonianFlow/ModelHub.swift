import FluidAudio
import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon

// Unit D (ModelHub). The single owner of every model in the process (24 GB machine, one process):
// lazy loads, one serial lane for Parakeet/CTC/Gemma work, unload policy, memory sampling.
// Callers: B (nemotron), C (parakeet), E and F (gemma, serial). Loads from the existing caches for now;
// downloads are Phase 4. Reference: scripts/coexist-bench main.swift (Serial actor, loaders) and
// scripts/llm-bench (Gemma loading; the n-1 prefill rule lives with the caller, in Polisher).
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

    /// Nemotron multilingual streaming manager for one channel (560 ms chunks, Latin ship), loaded lazily.
    func nemotron(_ channel: Channel) async throws -> StreamingNemotronMultilingualAsrManager { fatalError("Unit D") }

    /// Parakeet Ultra + CTC (ctc110m), loaded lazily.
    func parakeet() async throws -> ParakeetModels { fatalError("Unit D") }

    /// Gemma 4 E2B (4 bit), loaded lazily. Throws .modelMissing("gemma") when not downloaded.
    func gemma() async throws -> ModelContainer { fatalError("Unit D") }

    /// True when the cleanup model is on disk (drives EngineCapabilities.polish/.summary). Cheap, no load.
    nonisolated func gemmaAvailable() -> Bool { fatalError("Unit D") }

    func isLoaded(_ m: HubModel) -> Bool { fatalError("Unit D") }
    /// Drop a model from memory (the next accessor reloads it).
    func unload(_ m: HubModel) async { fatalError("Unit D") }
    /// Physical footprint of the process in MB (as coexist-bench physFootprintMB).
    nonisolated func footprintMB() -> Double { fatalError("Unit D") }

    /// Run `work` alone on the shared model lane: FIFO, one job at a time, held across awaits.
    nonisolated func serial<T>(_ work: () async throws -> T) async rethrows -> T {
        await gate.acquire()
        defer { gate.release() }
        return try await work()
    }

    private nonisolated let gate = SerialGate()
}

/// FIFO async mutex behind ModelHub.serial (an actor alone would interleave at every await).
final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy { waiters.append(c); lock.unlock() } else { busy = true; lock.unlock(); c.resume() }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty { busy = false; lock.unlock() } else { let next = waiters.removeFirst(); lock.unlock(); next.resume() }
    }
}
