import Foundation

// Phase 4: what the app downloads on first launch, and where it keeps it.
//
// Interface contract (skeleton): the setup guide and Settings (unit H) code against this file; the
// download implementation (unit G) fills in the bodies without changing the signatures below.
//  - Everything lives under `ModelStore.root` (~/Library/Application Support/Ionian Flow/Models), offline after
//    the first run. Nothing is hosted by us: speech models come from FluidAudio's Hugging Face repos, Gemma from
//    mlx-community on Hugging Face, mlx.metallib from the pinned MLX wheel on PyPI (sha256-checked).
//  - `.speech` is required (Nemotron live, Parakeet final, CTC vocabulary). `.cleanup` is optional (Gemma 4 E2B
//    plus mlx.metallib): skipping it turns cleanup, summaries and LLM vault extraction off; the sweep runs rules only.
//  - Downloads are resumable and idempotent: calling `download` for an installed item returns at once.

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

final class ModelStore: @unchecked Sendable {
    static let shared = ModelStore()

    /// ~/Library/Application Support/Ionian Flow/Models
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ionian Flow/Models", isDirectory: true)
    }

    /// True when every file of the item is on disk and complete. Cheap, no network, no model load.
    func isInstalled(_ item: ModelItem) -> Bool {
        fatalError("ModelStore.isInstalled: unit G")
    }

    /// Approximate download size, for the setup guide's "about X GB".
    func approximateBytes(_ item: ModelItem) -> Int64 {
        fatalError("ModelStore.approximateBytes: unit G")
    }

    /// Downloads what is missing, resuming partial files. `progress` gets 0...1 (any thread, throttled).
    /// Throws ModelStoreError; `.cancelled` after `cancel(item)`.
    func download(_ item: ModelItem, progress: @escaping @Sendable (Double) -> Void) async throws {
        fatalError("ModelStore.download: unit G")
    }

    /// Stops a running download of the item; partial files stay for the next resume.
    func cancel(_ item: ModelItem) {
        fatalError("ModelStore.cancel: unit G")
    }

    /// Deletes the item's files (Settings: "Remove cleanup model").
    func remove(_ item: ModelItem) throws {
        fatalError("ModelStore.remove: unit G")
    }
}
