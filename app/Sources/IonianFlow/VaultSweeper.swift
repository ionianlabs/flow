import Foundation

/// Learns the vocabulary from a vault with VaultSweep (Swift, Gemma through ModelHub): right after a vault is connected,
/// then whenever notes changed (checked at most every 30 min, and only while Ionian Flow is idle).
/// The scan is paused (SweepControl) while you dictate or transcribe, so it never competes with live
/// recognition for the GPU, and it runs at background task priority. The vault is only read.
final class VaultSweeper: ObservableObject {
    struct Vault: Hashable {
        let name: String
        let url: URL
    }

    enum Phase: Equatable {
        case idle
        case reading(done: Int, of: Int)
        case learning(done: Int, of: Int)
    }

    struct Result {
        let added: Int, removed: Int, total: Int
        let first: Bool  // the vault's first scan
        let requested: Bool  // you asked for it (connect, Rescan), rather than a background resync
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var running = false
    @Published private(set) var lastScan = Settings.lastVaultScan
    @Published private(set) var failed = false
    /// Dictating or transcribing: don't start a scan now.
    var isBusy: () -> Bool = { false }
    var onFinished: (Result) -> Void = { _ in }

    let logPath = NSHomeDirectory() + "/Library/Logs/Ionian Flow/sweep.log"
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var control: SweepControl?
    private var paused = false
    private var timer: Timer?
    private static let interval: TimeInterval = 30 * 60

    init() {}

    /// The vaults Obsidian knows, most recently opened first.
    static func knownVaults() -> [Vault] {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .compactMap { v -> (Vault, Double)? in
                guard let path = v["path"] as? String, FileManager.default.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                return (Vault(name: url.lastPathComponent, url: url), v["ts"] as? Double ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func name(of url: URL) -> String { url.lastPathComponent }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.maybeScan(force: false) }
        // Once at launch, after the app has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.maybeScan(force: true) }
    }

    func connect(_ url: URL) {
        cancel()
        Settings.vault = url
        Settings.lastVaultScan = nil
        lastScan = nil
        scan(requested: true)
    }

    /// Stops syncing; the terms learned so far stay in the file until you remove them.
    func disconnect() {
        cancel()
        Settings.vault = nil
    }

    /// `force`: skip the 30-minute spacing (launch), still only when something changed.
    private func maybeScan(force: Bool) {
        guard task == nil, let vault = Settings.vault, !isBusy() else { return }
        if let last = Settings.lastVaultScan {
            guard force || Date().timeIntervalSince(last) >= Self.interval, Self.changed(vault, since: last) else { return }
        }
        scan(requested: false)
    }

    /// Any note or folder modified since `date` (a deleted note bumps its folder).
    static func changed(_ vault: URL, since date: Date) -> Bool {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return false }
        if ((try? vault.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast) > date { return true }
        for case let url as URL in walk {
            if let m = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate, m > date { return true }
        }
        return false
    }

    /// `requested`: you're waiting for it, so it runs at normal priority. A background resync runs
    /// at background priority (slower, but you won't notice it).
    func scan(requested: Bool) {
        guard task == nil, let vault = Settings.vault else { return }
        var o = VaultSweep.Options(vault: vault, out: Settings.vocabularyFile)
        // The model is used when it is on disk; otherwise rules pick the terms.
        if ModelHub.shared.gemmaAvailable() { o.model = VaultSweep.modelID }
        let control = SweepControl()
        self.control = control
        let first = Settings.lastVaultScan == nil
        try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        running = true
        phase = .reading(done: 0, of: 0)
        failed = false
        paused = false
        if isBusy() { pause() }
        let id = UUID()
        taskID = id
        task = Task.detached(priority: requested ? .utility : .background) { [weak self, o] in
            do {
                let r = try await VaultSweep.run(o, makeLLM: { GemmaVaultLLM(control: control) }, control: control) { p in
                    DispatchQueue.main.async {
                        guard let self, self.taskID == id else { return }
                        switch p {
                        case .reading(let d, let n): self.phase = .reading(done: d, of: n)
                        case .learning(let d, let n): self.phase = .learning(done: d, of: n)
                        }
                    }
                }
                await MainActor.run { self?.finished(id, .success(r), first: first, requested: requested) }
            } catch {
                await MainActor.run { self?.finished(id, .failure(error), first: first, requested: requested) }
            }
        }
    }

    private func finished(_ id: UUID, _ outcome: Swift.Result<VaultSweep.Result, Error>, first: Bool, requested: Bool) {
        guard taskID == id else { return }
        task = nil
        control = nil
        taskID = nil
        running = false
        paused = false
        phase = .idle
        switch outcome {
        case .success(let r):
            Settings.lastVaultScan = Date()
            lastScan = Settings.lastVaultScan
            failed = false
            onFinished(Result(added: r.added, removed: r.removed, total: r.total, first: first, requested: requested))
        case .failure(let error):
            if error is CancellationError { return }
            NSLog("Ionian Flow: vault scan failed: %@", "\(error)")
            try? "\(error)\n".write(toFile: logPath, atomically: true, encoding: .utf8)
            failed = true
        }
    }

    /// While you dictate or transcribe. A paused scan keeps its place; the model gives its lane back within a token.
    func pause() {
        guard task != nil, !paused else { return }
        control?.pause()
        paused = true
    }

    func resume() {
        guard task != nil, paused else { return }
        control?.resume()
        paused = false
    }

    func cancel() {
        guard let t = task else { return }
        taskID = nil
        task = nil
        t.cancel()
        control?.resume()
        control = nil
        running = false
        paused = false
        phase = .idle
    }
}
