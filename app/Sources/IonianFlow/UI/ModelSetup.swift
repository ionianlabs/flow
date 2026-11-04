import AppKit
import SwiftUI

// Phase 4, unit H: the models step of the setup guide and the model rows in Settings.
// The UI talks to `ModelStoring` (ModelStore conforms below), so the state machine runs against a fake in the unit tests.

protocol ModelStoring: Sendable {
    func isInstalled(_ item: ModelItem) -> Bool
    func approximateBytes(_ item: ModelItem) -> Int64
    func download(_ item: ModelItem, progress: @escaping @Sendable (Double) -> Void) async throws
    func cancel(_ item: ModelItem)
    func remove(_ item: ModelItem) throws
}

extension ModelStore: ModelStoring {}

/// Where one model item stands.
enum ModelPhase: Equatable {
    case missing
    case downloading(Double)
    case paused(Double)  // cancelled: partial files stay, Resume continues
    case failed(String)
    case installed

    var isBusy: Bool { if case .downloading = self { return true } else { return false } }
}

/// Main thread only (UI and app delegate).
final class ModelSetupModel: ObservableObject {
    static let shared = ModelSetupModel(store: ModelStore.shared)

    @Published private(set) var phase: [ModelItem: ModelPhase] = [:]
    /// The person chose not to download the cleanup model (the step still lets them continue).
    @Published private(set) var cleanupSkipped = false

    /// Called after an item finished downloading or was removed: the app refreshes capabilities here.
    var onChange: (ModelItem) -> Void = { _ in }
    /// Called before files are deleted, so the app can drop the loaded model first.
    var onWillRemove: (ModelItem) async -> Void = { _ in }

    private let store: ModelStoring
    private var generation: [ModelItem: Int] = [:]

    init(store: ModelStoring) {
        self.store = store
        refresh()
    }

    func phase(_ item: ModelItem) -> ModelPhase { phase[item] ?? .missing }

    /// Re-reads the disk; keeps a running download or a failure as it is.
    func refresh() {
        for item in ModelItem.allCases {
            if store.isInstalled(item) { phase[item] = .installed }
            else if phase[item] == nil || phase[item] == .installed { phase[item] = .missing }
        }
    }

    /// Speech is required; everything else is optional.
    var canContinue: Bool { phase(.speech) == .installed }
    /// Nothing to offer: both models are already on disk, so the guide skips the step.
    var allInstalled: Bool { ModelItem.allCases.allSatisfy { phase($0) == .installed } }

    func bytesText(_ item: ModelItem) -> String { Self.sizeText(store.approximateBytes(item)) }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 0.95 { return String(format: "%.1f GB", gb) }
        return "\(max(10, Int((Double(bytes) / 10_000_000).rounded()) * 10)) MB"
    }

    /// Starts or resumes a download (also the retry after an error).
    func start(_ item: ModelItem) {
        guard !phase(item).isBusy, phase(item) != .installed else { return }
        if item == .cleanup { cleanupSkipped = false }
        let gen = (generation[item] ?? 0) + 1
        generation[item] = gen
        var from = 0.0
        if case .paused(let p) = phase(item) { from = p }
        phase[item] = .downloading(from)
        let store = self.store
        Task { @MainActor [weak self] in
            do {
                let report: @Sendable (Double) -> Void = { [weak self] p in
                    Task { @MainActor in self?.progressed(item, gen, p) }
                }
                try await store.download(item, progress: report)
                self?.finished(item, gen, nil)
            } catch {
                self?.finished(item, gen, error)
            }
        }
    }

    func cancel(_ item: ModelItem) {
        guard case .downloading(let p) = phase(item) else { return }
        generation[item] = (generation[item] ?? 0) + 1  // late results of the stopped download are ignored
        phase[item] = .paused(p)
        store.cancel(item)
    }

    func skipCleanup() {
        if phase(.cleanup).isBusy { cancel(.cleanup) }
        cleanupSkipped = true
    }

    func remove(_ item: ModelItem) {
        guard phase(item) == .installed else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onWillRemove(item)
            do {
                try self.store.remove(item)
                self.phase[item] = .missing
            } catch {
                self.phase[item] = .failed(Self.message(for: error))
            }
            self.onChange(item)
        }
    }

    private func progressed(_ item: ModelItem, _ gen: Int, _ p: Double) {
        guard generation[item] == gen, case .downloading(let old) = phase(item) else { return }
        phase[item] = .downloading(min(1, max(old, p)))
    }

    private func finished(_ item: ModelItem, _ gen: Int, _ error: Error?) {
        guard generation[item] == gen else { return }
        if let error {
            if case ModelStoreError.cancelled = error, case .paused = phase(item) { return }
            phase[item] = .failed(Self.message(for: error))
        } else {
            phase[item] = .installed
            onChange(item)
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error as? ModelStoreError {
        case .cancelled?: return "Stopped."
        case .network?: return "No connection, or the server did not answer."
        case .checksum?: return "A file did not match what was expected. Try again."
        case .disk?: return "Not enough disk space, or the folder is not writable."
        case nil: return error.localizedDescription
        }
    }
}

// MARK: - Setup guide step

struct ModelsStep: View {
    @ObservedObject var models: ModelSetupModel

    var body: some View {
        StepPage(title: Text("Get the models."),
                 lead: "Ionian Flow listens on your Mac, so it needs its models once. After that it works offline.") {
            VStack(alignment: .leading, spacing: Space.s4) {
                VStack(spacing: 0) {
                    Hairline()
                    ModelStepRow(models: models, item: .speech, title: "Speech",
                                 detail: "Download the speech models (about \(models.bytesText(.speech))). Required.")
                    Hairline()
                    ModelStepRow(models: models, item: .cleanup, title: "Cleanup, optional",
                                 detail: "Gemma, about \(models.bytesText(.cleanup)). Tidies transcripts and writes summaries.")
                    Hairline()
                }
                if models.cleanupSkipped && models.phase(.cleanup) != .installed {
                    Text("Without it, cleanup, summaries and LLM extraction from your vault stay off. The word scan then uses rules only. "
                         + "Add it any time in the Ionian Flow window.")
                        .ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if models.phase(.cleanup) == .missing {
                    Text("Skip it and Ionian Flow still types what you say. Cleanup, summaries and LLM extraction from your vault turn off.")
                        .ionianText(IonianType.small).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if models.phase(.speech) != .installed {
                    Text("You need the speech models to continue.").ionianText(IonianType.small).foregroundStyle(Color.muted)
                }
            }
        }
    }
}

private struct ModelStepRow: View {
    @ObservedObject var models: ModelSetupModel
    let item: ModelItem
    let title: String
    let detail: String

    var body: some View {
        let phase = models.phase(item)
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .top, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    Text(title).ionianText(IonianType.small, weight: 600).foregroundStyle(Color.ink)
                    Text(detail).ionianText(IonianType.small).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s3)
                VStack(alignment: .trailing, spacing: Space.s1) { controls(phase) }
                    .frame(width: 150, alignment: .trailing)
            }
            ModelProgress(phase: phase)
        }
        .padding(.vertical, Space.s3)
        .padding(.leading, Space.s1)
    }

    @ViewBuilder private func controls(_ phase: ModelPhase) -> some View {
        switch phase {
        case .installed:
            StatusDot(state: .ready, word: "Installed")
        case .downloading(let p):
            StatusDot(state: .working, word: "\(Int(p * 100))%")
            Button("Cancel ›") { models.cancel(item) }.buttonStyle(.monoLink)
        case .paused(let p):
            StatusDot(state: .off, word: "Paused \(Int(p * 100))%")
            Button("Resume ›") { models.start(item) }.buttonStyle(.monoLink)
        case .failed(let message):
            StatusDot(state: .off, word: "Failed")
            Text(message).ionianText(IonianType.caption).foregroundStyle(Color.ink)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            Button("Try again ›") { models.start(item) }.buttonStyle(.monoLink)
        case .missing:
            if item == .cleanup && models.cleanupSkipped {
                StatusDot(state: .off, word: "Skipped")
                Button("Download ›") { models.start(item) }.buttonStyle(.monoLink)
            } else {
                Button("Download ›") { models.start(item) }.buttonStyle(.monoLink)
                if item == .cleanup { Button("Skip ›") { models.skipCleanup() }.buttonStyle(.monoLink) }
            }
        }
    }
}

/// A thin linear bar while a download runs or waits to resume.
private struct ModelProgress: View {
    let phase: ModelPhase

    var body: some View {
        switch phase {
        case .downloading(let p), .paused(let p):
            ProgressView(value: p).progressViewStyle(.linear).tint(Color.ink).opacity(phase.isBusy ? 1 : 0.4)
        default:
            EmptyView()
        }
    }
}

// MARK: - Settings rows

/// The rows in General > Models: one short line each, the state and its action on the right, the detail in the tooltip.
/// Speech: the download phase, and once installed whether the recognizer itself is loaded (`recognizer`).
struct SpeechModelRow: View {
    @ObservedObject var models: ModelSetupModel
    var recognizer: StatusDot
    var reload: () -> Void

    /// The dot and word for the row: the download while there is one, otherwise the recognizer's own state.
    static func status(phase: ModelPhase, recognizer: (state: StatusState, word: String)) -> (state: StatusState, word: String) {
        switch phase {
        case .installed: return recognizer
        case .downloading(let p): return (.working, "Downloading \(Int(p * 100)) %")
        case .paused(let p): return (.off, "Paused at \(Int(p * 100)) %")
        case .failed: return (.off, "Error")
        case .missing: return (.off, "Not downloaded")
        }
    }

    var body: some View {
        let phase = models.phase(.speech)
        let status = Self.status(phase: phase, recognizer: (recognizer.state, recognizer.word))
        VStack(alignment: .leading, spacing: Space.s2) {
            SettingRow("Speech", "Required. On this Mac, offline.") {
                HStack(spacing: Space.s4) {
                    StatusDot(state: status.state, word: status.word, wordColor: Color.muted)
                    action(phase)
                }
                .buttonStyle(.monoLink)
            }
            ModelProgress(phase: phase)
        }
        .help("Nemotron for live text, Parakeet for the final pass, on this Mac's GPU. Nothing goes to the cloud. "
            + "About \(models.bytesText(.speech)), stored in Application Support.")
    }

    @ViewBuilder private func action(_ phase: ModelPhase) -> some View {
        switch phase {
        case .installed: Button("Reload ›", action: reload)
        case .downloading: Button("Cancel ›") { models.cancel(.speech) }
        case .paused: Button("Resume ›") { models.start(.speech) }
        case .failed: Button("Try again ›") { models.start(.speech) }
        case .missing: Button("Download ›") { models.start(.speech) }
        }
    }
}

struct CleanupModelRow: View {
    @ObservedObject var models: ModelSetupModel
    @State private var confirmRemove = false

    var body: some View {
        let phase = models.phase(.cleanup)
        VStack(alignment: .leading, spacing: Space.s2) {
            SettingRow("Cleanup", line(phase)) { trailing(phase) }
            ModelProgress(phase: phase)
        }
        .help("Gemma, on this Mac. It tidies transcripts, writes summaries and reads names from your vault. "
            + "Without it transcripts stay as heard, there is no summary, and the word scan uses rules only. "
            + "Stored in Application Support, works offline.")
        .confirmationDialog("Remove the cleanup model. You can download it again.", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { models.remove(.cleanup) }
        }
    }

    /// One short line: what it adds, and its size while it isn't on disk.
    func line(_ phase: ModelPhase) -> String {
        let adds = "Optional. Punctuation, summaries and vocabulary extraction."
        switch phase {
        case .installed: return adds
        case .failed(let message): return message
        default: return adds + " \(models.bytesText(.cleanup))."
        }
    }

    @ViewBuilder private func trailing(_ phase: ModelPhase) -> some View {
        switch phase {
        case .installed:
            HStack(spacing: Space.s4) {
                StatusDot(state: .ready, word: "On", wordColor: Color.muted)
                Button("Remove ›") { confirmRemove = true }.buttonStyle(.monoLink)
            }
        case .downloading(let p):
            HStack(spacing: Space.s4) {
                StatusDot(state: .working, word: "Downloading \(Int(p * 100)) %", wordColor: Color.muted)
                Button("Cancel ›") { models.cancel(.cleanup) }.buttonStyle(.monoLink)
            }
        case .paused:
            Button("Resume ›") { models.start(.cleanup) }.buttonStyle(.monoLink)
        case .failed:
            Button("Try again ›") { models.start(.cleanup) }.buttonStyle(.monoLink)
        case .missing:
            HStack(spacing: Space.s4) {
                StatusDot(state: .off, word: "Off", wordColor: Color.muted)
                Button("Download ›") { models.start(.cleanup) }.buttonStyle(.monoLink)
            }
        }
    }
}

/// A quiet footer link to the third-party notices file (shipped in the app's resources). Absent: no link.
struct ThirdPartyNoticesRow: View {
    static var url: URL? { Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md") }

    var body: some View {
        if let url = Self.url {
            Button("Third-party notices ↗") { NSWorkspace.shared.open(url) }
                .buttonStyle(.monoLink)
                .help("Licenses of the models and libraries Ionian Flow uses.")
                .padding(.horizontal, Space.s1)
        }
    }
}

// MARK: - Preview and test fakes

/// A store that never touches the network or disk: offscreen renders and the unit tests.
final class FakeModelStore: ModelStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Set<ModelItem>
    private var cancelled: Set<ModelItem> = []
    private var _hold = true, _fail: Set<ModelItem> = [], _cancelCalls = 0, _removeCalls = 0

    init(installed: Set<ModelItem> = []) { self.installed = installed }

    func with<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    /// While true, downloads sit at 40 % until released.
    var hold: Bool { get { with { _hold } } set { with { _hold = newValue } } }
    var cancelCalls: Int { with { _cancelCalls } }
    var removeCalls: Int { with { _removeCalls } }
    func failNext(_ item: ModelItem) { with { _ = _fail.insert(item) } }

    func isInstalled(_ item: ModelItem) -> Bool { with { installed.contains(item) } }
    func approximateBytes(_ item: ModelItem) -> Int64 { item == .speech ? 2_400_000_000 : 3_000_000_000 }

    func download(_ item: ModelItem, progress: @escaping @Sendable (Double) -> Void) async throws {
        with { _ = cancelled.remove(item) }
        progress(0.4)
        while true {
            if with({ cancelled.contains(item) }) { throw ModelStoreError.cancelled }
            if with({ _fail.remove(item) != nil }) { throw ModelStoreError.network("offline") }
            if !hold { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        progress(1)
        with { _ = installed.insert(item) }
    }

    func cancel(_ item: ModelItem) { with { _cancelCalls += 1; _ = cancelled.insert(item) } }
    func remove(_ item: ModelItem) throws { with { _removeCalls += 1; _ = installed.remove(item) } }
}
