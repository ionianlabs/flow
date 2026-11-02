import AppKit
import SwiftUI

/// What the Vocabulary page can ask the app to do.
struct VocabularyActions {
    var connect: (URL) -> Void
    var chooseFolder: () -> Void
    var disconnect: () -> Void
    var rescan: () -> Void
    var setUseVocabulary: (Bool) -> Void
}

/// The Vocabulary page: the vault and your field first, then the terms collapsed into categories.
/// New vault terms wait for a review.
struct VocabularyPage: View {
    @ObservedObject var store: VocabularyStore
    @ObservedObject var sweeper: VaultSweeper
    var actions: VocabularyActions
    @State private var query: String
    @State private var path: [String]
    @State private var domain = ""
    @State private var reviewing = false
    @State private var rejecting = false
    @State private var useVocabulary = Settings.useVocabulary

    init(store: VocabularyStore, sweeper: VaultSweeper, actions: VocabularyActions, query: String = "", open category: String? = nil) {
        self.store = store
        self.sweeper = sweeper
        self.actions = actions
        _query = State(initialValue: query)
        _path = State(initialValue: category.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPage(.vocabulary) {
                VaultSection(sweeper: sweeper, actions: actions)
                SettingsSection {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        SettingRow("Your field", "Helps the transcript cleanup pick the right words. Press Return to save.")
                        BrandField("For example civil engineering", text: $domain)
                            .onSubmit { store.setDomain(domain) }
                    }
                    SettingToggle("Use vocabulary", "Off: Ionian Flow transcribes as if the list were empty. This restarts the recognizer.", isOn: $useVocabulary)
                        .onChange(of: useVocabulary) { actions.setUseVocabulary(useVocabulary) }
                }
                if !store.unreviewed.isEmpty && !sweeper.running { reviewSection }
                termsSection
            }
            .navigationTitle(AppModel.Page.vocabulary.rawValue)
            .navigationDestination(for: String.self) { name in
                CategoryPage(store: store, name: name)
            }
        }
        .onAppear { domain = store.domain }
        .onChange(of: store.domain) { domain = store.domain }
        .sheet(isPresented: $reviewing) {
            ReviewSheet(store: store, entries: store.unreviewed) { reviewing = false }
        }
        .confirmationDialog("Reject all \(store.unreviewed.count) new terms?", isPresented: $rejecting) {
            Button("Reject All", role: .destructive) { store.ignoreAll(store.unreviewed) }
        } message: {
            Text("They go to Ignore, so the next scan won't bring them back.")
        }
    }

    private var reviewSection: some View {
        let n = store.unreviewed.count
        return SettingsSection {
            SettingRow("\(n) new \(n == 1 ? "term" : "terms") from your vault.", "Already active.") {
                HStack(spacing: Space.s4) {
                    Button("Reject all ›") { rejecting = true }.buttonStyle(.monoLink)
                    Button("Review…") { reviewing = true }.buttonStyle(.primaryCompact)
                }
            }
        }
    }

    // MARK: Terms

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var exactMatch: Bool { store.entries.contains { $0.id == trimmedQuery.lowercased() } }

    private var matches: [VocabularyStore.Entry] {
        let q = trimmedQuery.lowercased()
        return store.entries.filter { $0.id.contains(q) || $0.aliases.contains { $0.lowercased().contains(q) } }
    }

    private var termsSection: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            MonoLabel("Terms", color: Color.muted).padding(.horizontal, Space.s1).accessibilityAddTraits(.isHeader)
            BrandField("Search, or type a new term and press Return", text: $query)
                .onSubmit { if !trimmedQuery.isEmpty && !exactMatch { add("Terms") } }
            if trimmedQuery.isEmpty {
                if store.entries.isEmpty {
                    SettingsNote("No words yet. Connect a vault above, or type a name and press Return.")
                        .padding(.horizontal, Space.s1)
                } else {
                    SettingsCard {
                        ForEach(TermGroup.groups(store.entries), id: \.name) { group in
                            NavigationLink(value: group.name) {
                                SettingRow(group.name) {
                                    HStack(spacing: Space.s2) {
                                        MonoLabel("\(group.entries.count)", color: Color.muted)
                                        Text("›").ionianText(IonianType.body).foregroundStyle(Color.muted)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                SettingsCard {
                    if !exactMatch { addRow }
                    ForEach(matches) { TermRow(entry: $0) { store.remove($0) } }
                }
            }
            HStack {
                MonoLabel("\(store.entries.count) terms", color: Color.muted)
                Spacer()
                Button("Open as Markdown ↗") {
                    store.ensureFile()
                    NSWorkspace.shared.open(store.url)
                }
                .buttonStyle(.monoLink)
            }
            .padding(.horizontal, Space.s1)
        }
    }

    private var addRow: some View {
        Menu {
            ForEach(VocabularyStore.categories, id: \.self) { c in Button("Add to \(c)") { add(c) } }
        } label: {
            Text("Add “\(trimmedQuery)”").ionianText(IonianType.body).foregroundStyle(Color.ink)
        } primaryAction: { add("Terms") }
            .menuStyle(.button).buttonStyle(.plain)
            .help("Adds to Terms. The menu picks a category.")
    }

    private func add(_ category: String) {
        store.add(trimmedQuery, category: category)
        query = ""
    }
}

/// One category's terms, pushed from the Terms section.
private struct CategoryPage: View {
    @ObservedObject var store: VocabularyStore
    let name: String

    var body: some View {
        let entries = store.entries.filter { $0.category == name }
        SettingsPage(title: name) {
            SettingsSection(note: "Removing a vault term sends it to Ignore, so the next scan won't add it again.") {
                ForEach(entries) { TermRow(entry: $0) { store.remove($0) } }
                if entries.isEmpty { SettingRow("No terms left here.") }
            }
        }
        .navigationTitle(name)
    }
}

struct TermGroup {
    let name: String
    let entries: [VocabularyStore.Entry]

    static func groups(_ entries: [VocabularyStore.Entry]) -> [TermGroup] {
        let byCategory = Dictionary(grouping: entries, by: \.category)
        let order = VocabularyStore.categories + byCategory.keys.filter { !VocabularyStore.categories.contains($0) }.sorted()
        return order.compactMap { c in byCategory[c].map { TermGroup(name: c, entries: $0) } }
    }
}

/// The connected vault and its sync state, or the invitation to connect one.
private struct VaultSection: View {
    @ObservedObject var sweeper: VaultSweeper
    var actions: VocabularyActions

    var body: some View {
        SettingsSection("Vault") {
            if let vault = Settings.vault {
                SettingRow(VaultSweeper.name(of: vault)) {
                    HStack(spacing: Space.s4) {
                        Button("Rescan ›") { actions.rescan() }.buttonStyle(.monoLink).disabled(sweeper.running)
                        vaultMenu
                    }
                }
                if sweeper.running { progress }
                TimelineView(.periodic(from: .now, by: 30)) { _ in status }
            } else {
                SettingRow("Learn from your notes.", "Connect an Obsidian vault. Ionian Flow picks up names, acronyms and project words, "
                    + "and keeps up as you write. The vault is only read.") { vaultMenu }
            }
        }
    }

    @ViewBuilder private var progress: some View {
        switch sweeper.phase {
        case .reading(let done, let total) where total > 0, .learning(let done, let total) where total > 0:
            ProgressView(value: Double(done), total: Double(total)) {
                Text("Learning from notes · \(done) of \(total)").ionianText(IonianType.small).foregroundStyle(Color.muted)
            }
        default:
            ProgressView { Text("Starting").ionianText(IonianType.small).foregroundStyle(Color.muted) }.progressViewStyle(.linear)
        }
    }

    @ViewBuilder private var status: some View {
        if sweeper.running {
            SettingsNote("Scanning")
        } else if sweeper.failed {
            HStack(spacing: Space.s3) {
                SettingsNote("The last scan failed.", ink: true)
                Button("Open log ↗") { NSWorkspace.shared.open(URL(fileURLWithPath: sweeper.logPath)) }.buttonStyle(.monoLink)
            }
        } else if let last = sweeper.lastScan {
            SettingsNote("Synced " + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: .now)
                         + ". It rescans when your notes change.")
        } else {
            SettingsNote("Not scanned yet.")
        }
    }

    @ViewBuilder private var vaultMenu: some View {
        let menu = Menu(Settings.vault == nil ? "Connect Vault" : "Change ›") {
            let known = VaultSweeper.knownVaults()
            if !known.isEmpty {
                Section("Obsidian vaults") {
                    ForEach(known, id: \.self) { v in
                        Toggle(v.name, isOn: Binding(get: { Settings.vault == v.url }, set: { _ in actions.connect(v.url) }))
                    }
                }
            }
            Button("Choose Folder…", action: actions.chooseFolder)
            if Settings.vault != nil {
                Divider()
                Button("Disconnect", action: actions.disconnect)
            }
        }
        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        if Settings.vault == nil { menu.buttonStyle(.primaryCompact) } else { menu.buttonStyle(.monoLink) }
    }
}

private struct TermRow: View {
    let entry: VocabularyStore.Entry
    var onRemove: (VocabularyStore.Entry) -> Void
    @State private var hovering = false

    var body: some View {
        SettingRow(entry.text, entry.aliases.isEmpty ? nil : "heard as " + entry.aliases.joined(separator: ", ")) {
            HStack(spacing: Space.s3) {
                if entry.source == .mine { MonoLabel("Added by you", color: Color.muted) }
                Button("Remove") { onRemove(entry) }
                    .buttonStyle(.monoLink)
                    .opacity(hovering ? 1 : 0)
                    .help(entry.source == .mine ? "Remove this term" : "Remove it. The vault scan won't add it again.")
                    .accessibilityLabel("Remove \(entry.text)")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove") { onRemove(entry) } }
    }
}

/// New vault terms, all ticked: untick what doesn't belong, then Done. Unticked terms go to Ignore.
struct ReviewSheet: View {
    @ObservedObject var store: VocabularyStore
    let entries: [VocabularyStore.Entry]
    var onDone: () -> Void
    @State private var removing: Set<String> = []
    @State private var rejecting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s6) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Review new terms").ionianText(IonianType.title).foregroundStyle(Color.ink)
                        SettingsNote("Untick anything that isn't a name, product or term you use. Unticked terms go to Ignore, "
                            + "so the next scan won't bring them back.")
                    }
                    ForEach(TermGroup.groups(entries), id: \.name) { group in
                        SettingsSection(group.name) {
                            ForEach(group.entries) { e in
                                Toggle(isOn: Binding(
                                    get: { !removing.contains(e.id) },
                                    set: { keep in if keep { removing.remove(e.id) } else { removing.insert(e.id) } }
                                )) {
                                    Text(e.text).ionianText(IonianType.body).foregroundStyle(Color.ink)
                                }
                                .toggleStyle(.checkbox)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(Space.s6)
            }
            Hairline()
            HStack(spacing: Space.s4) {
                MonoLabel(removing.isEmpty ? "Keeping all \(entries.count)" : "Removing \(removing.count) of \(entries.count)", color: Color.muted)
                Spacer()
                Button("Reject all ›") { rejecting = true }.buttonStyle(.monoLink)
                Button("Later", action: onDone).buttonStyle(.monoLink).keyboardShortcut(.cancelAction)
                Button("Done") {
                    store.finishReview(of: entries, removing: removing)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primaryCompact)
            }
            .padding(Space.s4)
        }
        .frame(width: 480, height: 600)
        .background(Color.bg)
        .tint(Color.btnBg)
        .confirmationDialog("Reject all \(entries.count) new terms?", isPresented: $rejecting) {
            Button("Reject All", role: .destructive) {
                store.ignoreAll(entries)
                onDone()
            }
        } message: {
            Text("They go to Ignore, so the next scan won't bring them back.")
        }
    }
}
