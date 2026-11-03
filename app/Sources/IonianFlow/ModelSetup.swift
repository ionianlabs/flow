import AppKit
import SwiftUI

// Phase 4, unit H: the models step of the setup guide and the model rows in Settings.
// The UI talks to `ModelStoring` (ModelStore conforms below), so the state machine runs against a fake in --selftest.

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
                try await store.download(item) { p in
                    Task { @MainActor [weak self] in self?.progressed(item, gen, p) }
                }
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
            StatusDot(state: .working, word: "\(Int(p * 100)) %")
            Button("Cancel ›") { models.cancel(item) }.buttonStyle(.monoLink)
        case .paused(let p):
            StatusDot(state: .off, word: "Paused \(Int(p * 100)) %")
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

/// The two rows in General > Models. Used inside a `SettingsSection` (each row is one card row).
struct SpeechModelRow: View {
    @ObservedObject var models: ModelSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SettingRow("Speech", "Nemotron for live text, Parakeet for the final pass. About \(models.bytesText(.speech)). Required.") {
                trailing
            }
            ModelProgress(phase: models.phase(.speech))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch models.phase(.speech) {
        case .installed: StatusDot(state: .ready, word: "Installed", wordColor: Color.muted)
        case .downloading(let p):
            HStack(spacing: Space.s4) {
                StatusDot(state: .working, word: "\(Int(p * 100)) %", wordColor: Color.muted)
                Button("Cancel ›") { models.cancel(.speech) }.buttonStyle(.monoLink)
            }
        case .paused:
            Button("Resume ›") { models.start(.speech) }.buttonStyle(.monoLink)
        case .failed:
            Button("Try again ›") { models.start(.speech) }.buttonStyle(.monoLink)
        case .missing:
            Button("Download ›") { models.start(.speech) }.buttonStyle(.monoLink)
        }
    }
}

struct CleanupModelRow: View {
    @ObservedObject var models: ModelSetupModel
    @State private var confirmRemove = false

    var body: some View {
        let phase = models.phase(.cleanup)
        VStack(alignment: .leading, spacing: Space.s2) {
            SettingRow("Cleanup", detail(phase)) { trailing(phase) }
            ModelProgress(phase: phase)
        }
        .confirmationDialog("Remove the cleanup model. You can download it again.", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { models.remove(.cleanup) }
        }
    }

    private func detail(_ phase: ModelPhase) -> String {
        switch phase {
        case .installed:
            return "Gemma, on this Mac. Tidies transcripts, writes summaries and reads names from your vault."
        case .failed(let message):
            return message
        default:
            return "Off. Gemma, about \(models.bytesText(.cleanup)). Without it transcripts stay as heard, there is no summary, "
                + "and the word scan uses rules only."
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
                StatusDot(state: .working, word: "\(Int(p * 100)) %", wordColor: Color.muted)
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

/// Link to the third-party notices file (shipped in the app's resources by the download unit). Absent: no link.
struct ThirdPartyNoticesRow: View {
    static var url: URL? { Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md") }

    var body: some View {
        if let url = Self.url {
            SettingRow("Third-party notices", "Licenses of the models and libraries Ionian Flow uses.") {
                Button("Open ↗") { NSWorkspace.shared.open(url) }.buttonStyle(.monoLink)
            }
        }
    }
}

// MARK: - Preview and test fakes

/// A store that never touches the network or disk: offscreen renders and --selftest.
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

extension ModelSetupModel {
    /// State machine: missing, downloading, installed; cancel and resume; error and retry; skip; already installed; remove.
    static func selfTest() -> Bool {
        run()
    }

    private static func run() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL model setup: \(what)") } }
        func wait(_ what: String, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            check(cond(), "timeout: \(what)")
        }

        // Fresh install: speech missing, Continue locked.
        let store = FakeModelStore()
        let m = ModelSetupModel(store: store)
        var changed: [ModelItem] = []
        var willRemove: [ModelItem] = []
        m.onChange = { changed.append($0) }
        m.onWillRemove = { willRemove.append($0) }
        check(m.phase(.speech) == .missing && !m.canContinue && !m.allInstalled, "starts missing")
        check(m.bytesText(.speech) == "2.4 GB" && m.bytesText(.cleanup) == "3.0 GB", "size text")
        check(ModelSetupModel.sizeText(350_000_000) == "350 MB", "size text MB")

        // missing -> downloading -> installed
        m.start(.speech)
        check(m.phase(.speech).isBusy, "downloading after start")
        wait("progress") { m.phase(.speech) == .downloading(0.4) }
        store.hold = false
        wait("speech installed") { m.phase(.speech) == .installed }
        check(m.canContinue && changed == [.speech], "continue unlocked, onChange(speech) once")
        m.start(.speech)
        check(m.phase(.speech) == .installed, "start on installed is a no-op")

        // cancel -> paused -> resume -> installed
        store.hold = true
        m.start(.cleanup)
        wait("cleanup progress") { m.phase(.cleanup) == .downloading(0.4) }
        m.cancel(.cleanup)
        check(m.phase(.cleanup) == .paused(0.4) && store.cancelCalls == 1, "cancel pauses and tells the store")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(m.phase(.cleanup) == .paused(0.4), "late cancelled error does not turn into a failure")
        m.start(.cleanup)
        check(m.phase(.cleanup) == .downloading(0.4), "resume continues from the paused point")
        store.hold = false
        wait("cleanup installed") { m.phase(.cleanup) == .installed }
        check(changed == [.speech, .cleanup] && m.allInstalled, "cleanup installed")

        // remove cleanup
        m.remove(.cleanup)
        wait("cleanup removed") { m.phase(.cleanup) == .missing }
        check(willRemove == [.cleanup] && store.removeCalls == 1 && changed.last == .cleanup, "remove unloads first and notifies")

        // error -> retry; skip cleanup
        let s2 = FakeModelStore()
        let e = ModelSetupModel(store: s2)
        s2.failNext(.speech)
        e.start(.speech)
        wait("failed") { if case .failed = e.phase(.speech) { return true } else { return false } }
        check(!e.canContinue, "failure keeps Continue locked")
        s2.hold = false
        e.start(.speech)
        wait("retry installed") { e.phase(.speech) == .installed }
        e.skipCleanup()
        check(e.cleanupSkipped && e.canContinue && e.phase(.cleanup) == .missing, "skip cleanup: continue allowed, cleanup stays off")
        s2.hold = true
        e.start(.cleanup)
        check(!e.cleanupSkipped, "starting the download clears the skip")
        e.skipCleanup()
        check(e.cleanupSkipped && !e.phase(.cleanup).isBusy, "skip during a download pauses it")

        // already installed: nothing to do
        let done = ModelSetupModel(store: FakeModelStore(installed: [.speech, .cleanup]))
        check(done.allInstalled && done.canContinue, "installed users skip the step")

        check(ModelSetupModel.message(for: ModelStoreError.disk("x")).contains("disk"), "error text")
        print(failures == 0 ? "model setup self test OK" : "model setup self test FAILED")
        return failures == 0
    }
}
