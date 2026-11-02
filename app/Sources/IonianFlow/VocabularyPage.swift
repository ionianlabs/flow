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

/// The Vocabulary page of the Ionian Flow window: the connected vault, what its scan learned, and
/// your own terms. New vault terms wait for a review.
struct VocabularyPage: View {
    @ObservedObject var store: VocabularyStore
    @ObservedObject var sweeper: VaultSweeper
    var actions: VocabularyActions
    @State private var query = ""
    @State private var domain = ""
    @State private var reviewing = false
    @State private var rejecting = false
    @State private var useVocabulary = Settings.useVocabulary

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            PageHead(title: AppModel.Page.vocabulary.title, lead: AppModel.Page.vocabulary.subtitle)
                .frame(maxWidth: WindowLayout.lead, alignment: .leading)
                .padding(.bottom, Space.s2)
            VaultCard(sweeper: sweeper, actions: actions)
            if !store.unreviewed.isEmpty && !sweeper.running {
                reviewBanner
            }
            domainRow
            searchRow
            list
            footer
        }
        .frame(maxWidth: WindowLayout.content, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Space.s7)
        .padding(.top, Space.s8)
        .padding(.bottom, Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { domain = store.domain }
        .onChange(of: store.domain) { domain = store.domain }
        .sheet(isPresented: $reviewing) {
            ReviewSheet(store: store, entries: store.unreviewed) { reviewing = false }
        }
        .confirmationDialog("Reject all \(store.unreviewed.count) new terms?", isPresented: $rejecting) {
            Button("Reject all", role: .destructive) { store.ignoreAll(store.unreviewed) }
        } message: {
            Text("They go to Ignore, so the next scan won't bring them back.")
        }
    }

    private var reviewBanner: some View {
        let n = store.unreviewed.count
        return VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Space.s4) {
                Text("\(n) new \(n == 1 ? "term" : "terms") from your vault. Already active.")
                    .ionianText(IonianType.small).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s2)
                Button("Reject all ›") { rejecting = true }.buttonStyle(.monoLink)
                Button("Review ›") { reviewing = true }.buttonStyle(.monoLink)
            }
            .padding(.vertical, Space.s3)
            Hairline()
        }
    }

    private var domainRow: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            MonoLabel("Your field")
            TextField("For example civil engineering", text: $domain)
                .textFieldStyle(WellFieldStyle())
                .onSubmit { store.setDomain(domain) }
        }
        .help("What you work on. Helps the transcript cleanup pick the right words. Press Return to save.")
    }

    // MARK: Search and add

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var exactMatch: Bool { store.entries.contains { $0.id == trimmedQuery.lowercased() } }

    private var searchRow: some View {
        HStack(spacing: Space.s4) {
            TextField("Search, or type a new term and press Return", text: $query)
                .textFieldStyle(WellFieldStyle())
                .onSubmit { if !trimmedQuery.isEmpty && !exactMatch { add("Terms") } }
            Menu {
                ForEach(VocabularyStore.categories, id: \.self) { c in Button("Add to \(c)") { add(c) } }
            } label: {
                Text("Add +").ionianText(IonianType.label)
            } primaryAction: { add("Terms") }
                .menuStyle(.button)
                .buttonStyle(.monoLink)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(trimmedQuery.isEmpty || exactMatch)
                .help("Adds to Terms. The menu picks a category.")
        }
    }

    private func add(_ category: String) {
        store.add(trimmedQuery, category: category)
        query = ""
    }

    // MARK: List

    private var someReviewed: Bool { store.unreviewed.count < store.entries.filter { $0.source == .vault }.count }

    private var filtered: [VocabularyStore.Entry] {
        let q = trimmedQuery.lowercased()
        return store.entries.filter { e in q.isEmpty || e.id.contains(q) || e.aliases.contains { $0.lowercased().contains(q) } }
    }

    @ViewBuilder private var list: some View {
        if store.entries.isEmpty {
            emptyState("No words yet.", "Connect a vault above, or type a name and press Return.")
        } else if filtered.isEmpty {
            emptyState("Nothing matches.", "Press Return to add “\(trimmedQuery)”.")
        } else {
            VStack(spacing: 0) {
                Hairline()
                List {
                    ForEach(TermGroup.groups(filtered), id: \.name) { group in
                        Section {
                            // Dots only mean something once part of the list is reviewed; the banner covers "all new".
                            ForEach(group.entries) { EntryRow(entry: $0, isNew: someReviewed && store.isNew($0)) { store.remove($0) } }
                                .listRowSeparatorTint(Color.line)
                        } header: {
                            MonoLabel("\(group.name) · \(group.entries.count)").padding(.top, Space.s3)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.bg)
                Hairline()
            }
            .frame(minHeight: 140, maxHeight: .infinity)  // scroll in the space left; never size the window
        }
    }

    private func emptyState(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).ionianText(IonianType.card).foregroundStyle(Color.ink)
            Text(text).ionianText(IonianType.small).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, Space.s4)
    }

    private var footer: some View {
        HStack(spacing: Space.s4) {
            Toggle("Use vocabulary", isOn: $useVocabulary)
                .toggleStyle(.switch)
                .tint(Color.btnBg)
                .ionianText(IonianType.small)
                .onChange(of: useVocabulary) { actions.setUseVocabulary(useVocabulary) }
                .help("Off: Ionian Flow transcribes as if the list were empty. This restarts the recognizer.")
            Spacer()
            MonoLabel("\(store.entries.count) terms")
            Button("Open as Markdown ↗") {
                store.ensureFile()
                NSWorkspace.shared.open(store.url)
            }
            .buttonStyle(.monoLink)
        }
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
private struct VaultCard: View {
    @ObservedObject var sweeper: VaultSweeper
    var actions: VocabularyActions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            MonoLabel("Vault")
            Hairline()
            if let vault = Settings.vault {
                HStack(alignment: .top, spacing: Space.s4) {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(VaultSweeper.name(of: vault)).ionianText(IonianType.small, weight: 600).foregroundStyle(Color.ink)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in status }
                    }
                    Spacer(minLength: Space.s2)
                    Button("Rescan ›") { actions.rescan() }
                        .buttonStyle(.monoLink)
                        .disabled(sweeper.running)
                    vaultMenu
                }
                if sweeper.running { progress }
            } else {
                HStack(alignment: .center, spacing: Space.s4) {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text("Learn from your notes.").ionianText(IonianType.small, weight: 600).foregroundStyle(Color.ink)
                        Text("Connect an Obsidian vault. Ionian Flow picks up names, acronyms and project words, "
                            + "and keeps up as you write. The vault is only read.")
                            .ionianText(IonianType.small).foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.s2)
                    vaultMenu
                }
            }
        }
    }

    @ViewBuilder private var progress: some View {
        switch sweeper.phase {
        case .reading(let done, let total) where total > 0, .learning(let done, let total) where total > 0:
            ProgressView(value: Double(done), total: Double(total)) {
                MonoLabel("Learning from notes · \(done) of \(total)")
            }
            .tint(Color.btnBg)
        default:
            ProgressView { MonoLabel("Starting") }.progressViewStyle(.linear).tint(Color.btnBg)
        }
    }

    @ViewBuilder private var status: some View {
        if sweeper.running {
            Text("Scanning").ionianText(IonianType.small).foregroundStyle(Color.muted)
        } else if sweeper.failed {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("The last scan failed. The log is here:").ionianText(IonianType.small).foregroundStyle(Color.ink)
                Button("Open log ↗") { NSWorkspace.shared.open(URL(fileURLWithPath: sweeper.logPath)) }
                    .buttonStyle(.monoLink)
            }
        } else if let last = sweeper.lastScan {
            Text("Synced " + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: .now)
                 + ". It rescans when your notes change.")
                .ionianText(IonianType.small).foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Not scanned yet.").ionianText(IonianType.small).foregroundStyle(Color.muted)
        }
    }

    private var vaultMenu: some View {
        Menu {
            let known = VaultSweeper.knownVaults()
            if !known.isEmpty {
                Section("Obsidian vaults") {
                    ForEach(known, id: \.self) { v in
                        Toggle(v.name, isOn: Binding(get: { Settings.vault == v.url }, set: { _ in actions.connect(v.url) }))
                    }
                }
            }
            Button("Choose folder…", action: actions.chooseFolder)
            if Settings.vault != nil {
                Divider()
                Button("Disconnect", action: actions.disconnect)
            }
        } label: {
            Text(Settings.vault == nil ? "Connect vault" : "Change ›")
        }
        .menuStyle(.button)
        .buttonStyle(Settings.vault == nil ? AnyButtonStyle(.primary) : AnyButtonStyle(.monoLink))
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct EntryRow: View {
    let entry: VocabularyStore.Entry
    let isNew: Bool
    var onRemove: (VocabularyStore.Entry) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.s2) {
            if isNew {
                HStack(spacing: Space.s1) {  // the dot never sits alone (STS-01)
                    Circle().fill(Color.building).frame(width: 7, height: 7)
                    MonoLabel("New")
                }
                .help("Not reviewed yet")
            }
            Text(entry.text).ionianText(IonianType.small).foregroundStyle(Color.ink)
            if !entry.aliases.isEmpty {
                Text("heard as " + entry.aliases.joined(separator: ", "))
                    .ionianText(IonianType.small).foregroundStyle(Color.muted).lineLimit(1)
            }
            Spacer(minLength: Space.s1)
            MonoLabel(entry.source == .mine ? "Yours" : "Vault")
            Button("Remove ›") { onRemove(entry) }
                .buttonStyle(.monoLink)
                .opacity(hovering ? 1 : 0)
                .help(entry.source == .mine ? "Remove this term" : "Remove it. The vault scan won't add it again.")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
        VStack(alignment: .leading, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Review new terms.").ionianText(IonianType.card).foregroundStyle(Color.ink)
                Text("Untick anything that isn't a name, product or term you use. Unticked terms go to Ignore, "
                    + "so the next scan won't bring them back.")
                    .ionianText(IonianType.small).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                Hairline()
                List {
                    ForEach(TermGroup.groups(entries), id: \.name) { group in
                        Section {
                            ForEach(group.entries) { e in
                                Toggle(isOn: Binding(
                                    get: { !removing.contains(e.id) },
                                    set: { keep in if keep { removing.remove(e.id) } else { removing.insert(e.id) } }
                                )) {
                                    Text(e.text).ionianText(IonianType.small).foregroundStyle(Color.ink)
                                }
                                .toggleStyle(.checkbox)
                                .listRowSeparatorTint(Color.line)
                            }
                        } header: {
                            MonoLabel(group.name)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.bg)
                Hairline()
            }
            .frame(minHeight: 320)
            HStack(spacing: Space.s4) {
                MonoLabel(removing.isEmpty ? "Keeping all \(entries.count)" : "Removing \(removing.count) of \(entries.count)")
                Spacer()
                Button("Reject all ›") { rejecting = true }.buttonStyle(.monoLink)
                Button("Later ›", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(.monoLink)
                Button("Done") {
                    store.finishReview(of: entries, removing: removing)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primaryCompact)
            }
        }
        .padding(Space.s6)
        .frame(width: WindowLayout.review.width, height: WindowLayout.review.height)
        .background(Color.bg)
        .tint(Color.btnBg)
        .confirmationDialog("Reject all \(entries.count) new terms?", isPresented: $rejecting) {
            Button("Reject all", role: .destructive) {
                store.ignoreAll(entries)
                onDone()
            }
        } message: {
            Text("They go to Ignore, so the next scan won't bring them back.")
        }
    }
}
