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
            Form {
                VaultSection(sweeper: sweeper, actions: actions)
                Section {
                    TextField(text: $domain, prompt: Text("For example civil engineering")) {
                        SettingLabel("Your field", "Helps the transcript cleanup pick the right words. Press Return to save.")
                    }
                    .onSubmit { store.setDomain(domain) }
                    Toggle(isOn: $useVocabulary) {
                        SettingLabel("Use vocabulary", "Off: Ionian Flow transcribes as if the list were empty. This restarts the recognizer.")
                    }
                    .onChange(of: useVocabulary) { actions.setUseVocabulary(useVocabulary) }
                }
                if !store.unreviewed.isEmpty && !sweeper.running { reviewSection }
                termsSection
            }
            .formStyle(.grouped)
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
        return Section {
            LabeledContent {
                HStack(spacing: 12) {
                    Button("Review…") { reviewing = true }
                    Button("Reject All") { rejecting = true }
                }
            } label: {
                Text("\(n) new \(n == 1 ? "term" : "terms") from your vault. Already active.")
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
        Section {
            TextField("Search", text: $query, prompt: Text("Search, or type a new term and press Return"))
                .labelsHidden()
                .onSubmit { if !trimmedQuery.isEmpty && !exactMatch { add("Terms") } }
            if trimmedQuery.isEmpty {
                if store.entries.isEmpty {
                    Text("No words yet. Connect a vault above, or type a name and press Return.").foregroundStyle(.secondary)
                }
                ForEach(TermGroup.groups(store.entries), id: \.name) { group in
                    NavigationLink(value: group.name) {
                        LabeledContent(group.name, value: "\(group.entries.count)")
                    }
                }
            } else {
                if !exactMatch { addRow }
                ForEach(matches) { TermRow(entry: $0) { store.remove($0) } }
            }
        } header: {
            Text("Terms")
        } footer: {
            HStack {
                Text("\(store.entries.count) terms")
                Spacer()
                Button("Open as Markdown") {
                    store.ensureFile()
                    NSWorkspace.shared.open(store.url)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var addRow: some View {
        Menu {
            ForEach(VocabularyStore.categories, id: \.self) { c in Button("Add to \(c)") { add(c) } }
        } label: {
            Text("Add “\(trimmedQuery)”")
        } primaryAction: { add("Terms") }
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
        Form {
            Section {
                ForEach(entries) { TermRow(entry: $0) { store.remove($0) } }
                if entries.isEmpty { Text("No terms left here.").foregroundStyle(.secondary) }
            } footer: {
                Text("Removing a vault term sends it to Ignore, so the next scan won't add it again.")
            }
        }
        .formStyle(.grouped)
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
        Section("Vault") {
            if let vault = Settings.vault {
                LabeledContent {
                    HStack(spacing: 12) {
                        Button("Rescan") { actions.rescan() }.disabled(sweeper.running)
                        vaultMenu
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(VaultSweeper.name(of: vault))
                        TimelineView(.periodic(from: .now, by: 30)) { _ in status }
                    }
                }
                if sweeper.running { progress }
            } else {
                LabeledContent {
                    vaultMenu
                } label: {
                    SettingLabel("Learn from your notes.", "Connect an Obsidian vault. Ionian Flow picks up names, acronyms and project words, "
                        + "and keeps up as you write. The vault is only read.")
                }
            }
        }
    }

    @ViewBuilder private var progress: some View {
        switch sweeper.phase {
        case .reading(let done, let total) where total > 0, .learning(let done, let total) where total > 0:
            ProgressView(value: Double(done), total: Double(total)) { Text("Learning from notes · \(done) of \(total)") }
        default:
            ProgressView { Text("Starting") }.progressViewStyle(.linear)
        }
    }

    @ViewBuilder private var status: some View {
        if sweeper.running {
            Text("Scanning").font(.footnote).foregroundStyle(.secondary)
        } else if sweeper.failed {
            HStack(spacing: 8) {
                Text("The last scan failed. The log is here:").font(.footnote)
                Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: sweeper.logPath)) }
                    .controlSize(.small)
            }
        } else if let last = sweeper.lastScan {
            Text("Synced " + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: .now)
                 + ". It rescans when your notes change.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("Not scanned yet.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var vaultMenu: some View {
        Menu(Settings.vault == nil ? "Connect Vault" : "Change") {
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
        .fixedSize()
    }
}

private struct TermRow: View {
    let entry: VocabularyStore.Entry
    var onRemove: (VocabularyStore.Entry) -> Void
    @State private var hovering = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if entry.source == .mine { Text("Added by you").font(.footnote).foregroundStyle(.secondary) }
                Button { onRemove(entry) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .opacity(hovering ? 1 : 0)
                    .help(entry.source == .mine ? "Remove this term" : "Remove it. The vault scan won't add it again.")
                    .accessibilityLabel("Remove \(entry.text)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                if !entry.aliases.isEmpty {
                    Text("heard as " + entry.aliases.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Review new terms").font(.headline)
                Text("Untick anything that isn't a name, product or term you use. Unticked terms go to Ignore, "
                    + "so the next scan won't bring them back.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            Form {
                ForEach(TermGroup.groups(entries), id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.entries) { e in
                            Toggle(e.text, isOn: Binding(
                                get: { !removing.contains(e.id) },
                                set: { keep in if keep { removing.remove(e.id) } else { removing.insert(e.id) } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Text(removing.isEmpty ? "Keeping all \(entries.count)" : "Removing \(removing.count) of \(entries.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reject All") { rejecting = true }
                Button("Later", action: onDone).keyboardShortcut(.cancelAction)
                Button("Done") {
                    store.finishReview(of: entries, removing: removing)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 480, height: 600)
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
