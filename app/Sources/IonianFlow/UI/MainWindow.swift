import AppKit
import ServiceManagement
import SwiftUI

/// State the Ionian Flow window shows; the app delegate keeps it current.
final class AppModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", shortcuts = "Shortcuts", dictation = "Dictation", transcription = "Transcription", vocabulary = "Vocabulary"
        var id: String { rawValue }
    }

    @Published var page = Page.general
    @Published var status = "ASR: loading models"
    /// The cleanup model is downloaded (polish and summaries are on).
    @Published var cleanupAvailable = true
    @Published var transcribing = false
    @Published var transcriptsFolder = Settings.transcriptsFolder
    /// The event tap is running (Input Monitoring granted and taking effect).
    @Published var hotkeyActive = false
    /// Bumped when shortcuts change, so hints redraw.
    @Published var shortcutsRevision = 0
    /// Bumped when a dictation or transcript adds to the totals.
    @Published var statsRevision = 0
}

/// What the window's pages can ask the app to do (settings with side effects go through here).
struct AppActions {
    var toggleTranscription: () -> Void
    var reloadEngine: () -> Void
    var chooseTranscriptsFolder: () -> Void
    var openTranscripts: () -> Void
    var setMicrophone: (String) -> Void
    var setKeepMicWarm: (Bool) -> Void
    var applyShortcuts: () -> Void
    var showSetupGuide: () -> Void
    var models: ModelSetupModel
    var vocabulary: VocabularyActions
    var setInstinct: (Bool) -> Void = { _ in }
}

/// The Ionian Flow window: settings and the vocabulary, one page each, in Ionian Flow's brand skin (see
/// Theme.swift) on a native split view and sidebar. While it's open Ionian Flow is a regular app (Dock,
/// ⌘-Tab, an app menu, and with it ⌘C/⌘V in text fields); closed, it's back to the menu bar only.
final class MainWindow {
    let model: AppModel
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    init(model: AppModel, store: VocabularyStore, sweeper: VaultSweeper, actions: AppActions) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WindowLayout.main.width, height: WindowLayout.main.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Ionian Flow"
        window.isReleasedWhenClosed = false
        window.minSize = WindowLayout.mainMin
        let host = NSHostingView(rootView: MainView(model: model, store: store, sweeper: sweeper, actions: actions))
        host.sizingOptions = []  // the window keeps its size (and minSize); long lists scroll
        window.contentView = host
        window.setContentSize(WindowLayout.main)
        if !window.setFrameUsingName("IonianFlowMain") { window.center() }
        window.setFrameAutosaveName("IonianFlowMain")
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [window] _ in
            // Back to the menu bar only, unless the setup guide is still open.
            if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func show(_ page: AppModel.Page? = nil) {
        if let page { model.page = page }
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.appMenu() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()  // a menu bar app's window would otherwise stay behind
        window.makeKeyAndOrderFront(nil)
    }

    /// Ionian Flow, Edit and Window menus: shown while the window is open. Without an Edit menu, text
    /// fields get no ⌘C/⌘V.
    private static func appMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        menu("Ionian Flow", [
            item("Hide Ionian Flow", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Ionian Flow", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }
}

extension AppModel.Page {
    /// The page's headline: a short statement (VOI-03). The sidebar keeps the one-word name.
    var title: String {
        switch self {
        case .general: return "Talk, and it types."
        case .shortcuts: return "Your keys."
        case .dictation: return "Hold, talk, let go."
        case .transcription: return "Meetings as Markdown."
        case .vocabulary: return "Your words."
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Ionian Flow turns your voice into text at your cursor. It runs on this Mac."
        case .shortcuts: return "Hold a key to dictate. Press keys to transcribe or cancel."
        case .dictation: return "Your text lands where the cursor is."
        case .transcription: return "Written while you talk: you and the other side."
        case .vocabulary: return "Names, acronyms and project words Flow should get right."
        }
    }
}

extension AppModel {
    var recognizerReady: Bool { status.hasSuffix("ready") && !status.contains("not") }
    var recognizerFailed: Bool { status.hasSuffix("error") }

    /// The speech model's state as a dot with its word (MAC-09).
    var recognizerStatus: StatusDot {
        if recognizerReady { return StatusDot(state: .ready, word: "Ready") }
        let text = status.replacingOccurrences(of: "ASR: ", with: "").replacingOccurrences(of: "ASR ", with: "Speech model ")
            .replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        return StatusDot(state: status.hasPrefix("Grant") || status.contains("not downloaded") || recognizerFailed ? .off : .working, word: text.capitalizingFirst)
    }
}

private struct MainView: View {
    @ObservedObject var model: AppModel
    var store: VocabularyStore
    @ObservedObject var sweeper: VaultSweeper
    var actions: AppActions
    var query = ""  // starting state for the offscreen renderer
    var category: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, sweeper: sweeper)
                .navigationSplitViewColumnWidth(min: 180, ideal: WindowLayout.sidebar, max: 280)
        } detail: {
            Group {
                switch model.page {
                case .general: GeneralPage(model: model, actions: actions)
                case .shortcuts: ShortcutsPage(model: model, actions: actions)
                case .dictation: DictationPage(actions: actions)
                case .transcription: TranscriptionPage(model: model, actions: actions)
                case .vocabulary: VocabularyPage(store: store, sweeper: sweeper, actions: actions.vocabulary, query: query, open: category)
                }
            }
            .navigationTitle(model.page.rawValue)
        }
    }
}

extension AppModel.Page {
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .dictation: return "mic"
        case .transcription: return "text.bubble"
        case .vocabulary: return "character.book.closed"
        }
    }
}

/// The app mark, the pages (⌘1–⌘5), and at the bottom whether the speech model is ready.
private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sweeper: VaultSweeper
    @Environment(\.ionianOffscreen) private var offscreen  // the live sidebar material can't be drawn offscreen
    private let version = UserDefaults.standard.string(forKey: "renderVersion")  // set by --render only
        ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some View {
        List(selection: Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
            ForEach(AppModel.Page.allCases) { page in
                HStack {
                    Label { Text(page.rawValue).ionianText(IonianType.small) } icon: { Image(systemName: page.symbol).foregroundStyle(offscreen ? Color.muted : Color.secondary) }
                    if page == .vocabulary && sweeper.running {
                        Spacer()
                        ProgressView().controlSize(.mini)
                    }
                }
                .tag(page)
            }
        }
        .listStyle(.sidebar)
        .tint(Color.btnBg)
        .scrollContentBackground(offscreen ? .hidden : .automatic)
        .background(offscreen ? Color.surface : Color.clear)
        .safeAreaInset(edge: .top, spacing: 0) {
            Lockup().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if model.transcribing { StatusDot(state: .working, word: "Transcribing", wordColor: Color.muted) }
                StatusDot(state: model.recognizerStatus.state, word: model.recognizerStatus.word, wordColor: Color.muted)
                MonoLabel("On this Mac · \(version)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background {
            ForEach(Array(AppModel.Page.allCases.enumerated()), id: \.element) { i, page in
                Button(page.rawValue) { model.page = page }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// The pure parts of the General page: the totals line and when the how-to shows.
enum GeneralLayout {
    /// The renderer pins this to en_US so the sample reads "2,545" on every Mac.
    nonisolated(unsafe) static var numberLocale = Locale.autoupdatingCurrent

    struct Total: Equatable {
        var value: String
        var label: String
    }

    /// "2,545 words", "23 min of meetings", "≈ 46 min saved": value in mono, label muted.
    static func totals(words: Int, transcribedSeconds: Int, savedSeconds: Int) -> [Total] {
        [Total(value: words.formatted(.number.locale(numberLocale)), label: words == 1 ? "word" : "words"),
         Total(value: duration(transcribedSeconds), label: "of meetings"),
         Total(value: (savedSeconds >= 60 ? "≈ " : "") + duration(savedSeconds), label: "saved")]
    }

    /// "2,545 words · 23 min of meetings · ≈ 46 min saved".
    static func line(_ totals: [Total]) -> String { totals.map { "\($0.value) \($0.label)" }.joined(separator: " · ") }

    /// The how-to is for the first run: it goes once something has been dictated or transcribed.
    static func showHowTo(words: Int, transcribedSeconds: Int) -> Bool { words == 0 && transcribedSeconds == 0 }

    /// "0 min", "42 min", "3 h", "6 h 40 min".
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60, h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(minutes) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var sounds = Settings.sounds
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var instinct = Settings.instinct

    var body: some View {
        let _ = model.statsRevision
        let _ = model.shortcutsRevision
        SettingsPage(.general) {
            StatsSection(model: model)
            if !model.hotkeyActive { PermissionsNotice(actions: actions) }
            if GeneralLayout.showHowTo(words: Stats.words, transcribedSeconds: Stats.transcribedSeconds) { HowToSection() }
            SettingsSection("App") {
                SettingToggle("Sounds", "A short sound when dictation starts and ends.", isOn: $sounds)
                    .onChange(of: sounds) { Settings.sounds = sounds }
                SettingToggle("Launch at login", isOn: $login)
                    .onChange(of: login) {
                        do {
                            if login { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Ionian Flow: launch at login failed: %@", error.localizedDescription)
                            login = SMAppService.mainApp.status == .enabled
                        }
                    }
                SettingRow("Setup guide", "Permissions, your dictation key and a field to try it.") {
                    Button("Open ›", action: actions.showSetupGuide).buttonStyle(.monoLink)
                }
            }
            SettingsSection("Brain") {
                SettingToggle(InstinctApp.toggleTitle, InstinctApp.toggleDetail, isOn: $instinct)
                    .onChange(of: instinct) { actions.setInstinct(instinct) }
            }
            SettingsSection("Models") {
                SpeechModelRow(models: actions.models, recognizer: model.recognizerStatus, reload: actions.reloadEngine)
                CleanupModelRow(models: actions.models)
            }
            ThirdPartyNoticesRow()
        }
    }
}

/// What Flow has done for you so far: words dictated, meetings transcribed, typing time saved, on one line.
private struct StatsSection: View {
    @ObservedObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        let _ = model.statsRevision
        let empty = Stats.words == 0 && Stats.transcribedSeconds == 0
        let totals = GeneralLayout.totals(words: Stats.words, transcribedSeconds: Stats.transcribedSeconds, savedSeconds: Stats.savedSeconds)
        SettingsSection("So far", accessory: {
            if !empty { Button("Reset ›") { confirmReset = true }.buttonStyle(.monoLink) }
        }, footer: {
            if empty { SettingsNote("Your first dictation starts the count. Flow keeps only the totals, never the text.") }
        }) {
            // One line; at a narrow width the three totals stack instead of breaking mid-phrase.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s2) { items(totals) }
                VStack(alignment: .leading, spacing: 0) { ForEach(totals, id: \.label) { total($0) } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Space.s6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GeneralLayout.line(totals))
        }
        .confirmationDialog("Reset the totals to zero.", isPresented: $confirmReset) {
            Button("Reset") {
                Stats.reset()
                model.statsRevision += 1
            }
        }
    }

    @ViewBuilder private func items(_ totals: [GeneralLayout.Total]) -> some View {
        ForEach(Array(totals.enumerated()), id: \.offset) { i, t in
            if i > 0 { Text("·").ionianText(IonianType.small).foregroundStyle(Color.muted) }
            total(t)
        }
    }

    private func total(_ t: GeneralLayout.Total) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
            Text(t.value).ionianText(IonianType.code).foregroundStyle(Color.ink)
            Text(t.label).ionianText(IonianType.small).foregroundStyle(Color.muted)
        }
        .fixedSize()
    }
}

/// How it works, in three steps: hold your key, talk, let go. Shown until the first dictation; the other keys
/// live on the Shortcuts page.
private struct HowToSection: View {
    /// The wave visual is 52 pt tall, the pill's wave is 30.
    private static let waveScale: CGFloat = 52 / 30
    private static let visualHeight: CGFloat = 64

    var body: some View {
        let key = Settings.dictationKey
        SettingsSection("How it works") {
            HStack(alignment: .top, spacing: Space.s5) {
                step("Hold the key", "Hold \(key.name) wherever you can type.") {
                    Key(label: key.keyLabel, size: key == .fn ? 16 : 24, held: true).scaleEffect(0.8, anchor: .leading)
                }
                step("Speak", "Talk as you would to a colleague.") {
                    Wave(bars: 11, scale: Self.waveScale)
                }
                step("Let go", "Clean text appears at your cursor.") {
                    Text("The launch moves to Thursday.")
                        .ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .padding(.leading, 10).padding(.vertical, 2)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.ink).frame(width: 2) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Space.s2)
        }
    }

    private func step<V: View>(_ title: String, _ text: String, @ViewBuilder visual: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            visual().frame(height: Self.visualHeight, alignment: .leading)
            Text(title).ionianText(IonianType.small, weight: 600).foregroundStyle(Color.ink).padding(.top, 6)
            Text(text).ionianText(IonianType.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keys can't work without permissions: a plain sentence and the way to fix it.
private struct PermissionsNotice: View {
    var actions: AppActions

    var body: some View {
        SettingsSection {
            SettingRow("Keys need permissions.") {
                Button("Open setup guide ›", action: actions.showSetupGuide).buttonStyle(.monoLink)
            }
        }
    }
}

private struct ShortcutsPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var key = Settings.dictationKey
    @State private var transcription = Settings.transcriptionShortcut
    @State private var handsFree = Settings.handsFreeShortcut
    @State private var cancel: Shortcut? = Settings.cancelShortcut == .escape ? nil : Settings.cancelShortcut

    var body: some View {
        SettingsPage(.shortcuts) {
            SettingsSection(note: model.hotkeyActive
                ? "Click a shortcut, then press the keys. Combinations need ⌘, ⌥ or ⌃."
                : "Shortcuts don't work yet. Allow Input Monitoring and Accessibility, then restart Flow.",
                ink: !model.hotkeyActive) {
                SettingRow("Dictate", "Hold this key while you talk.") {
                    Picker("Dictate", selection: $key) {
                        ForEach(DictationKey.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: key) { Settings.dictationKey = key; actions.applyShortcuts() }
                }
                SettingRow("Transcribe a meeting", "Opens the transcript panel. The same keys stop it.") {
                    ShortcutRecorder(shortcut: $transcription, placeholder: "Double-tap \(key.name)") {
                        Settings.transcriptionShortcut = transcription
                        actions.applyShortcuts()
                    }
                }
                SettingRow("Hands-free dictation", "Dictate without holding a key. Tap the key to finish.") {
                    ShortcutRecorder(shortcut: $handsFree, placeholder: "Menu bar only") {
                        Settings.handsFreeShortcut = handsFree
                        actions.applyShortcuts()
                    }
                }
                SettingRow("Cancel a dictation", "Nothing is pasted.") {
                    ShortcutRecorder(shortcut: $cancel, placeholder: "Esc", requireModifier: false) {
                        Settings.cancelShortcut = cancel ?? .escape
                        actions.applyShortcuts()
                    }
                }
            }
            if !model.hotkeyActive { PermissionsNotice(actions: actions) }
        }
    }
}

private struct DictationPage: View {
    var actions: AppActions
    @State private var language = Settings.language
    @State private var microphone = Settings.microphone
    @State private var trailingSpace = Settings.trailingSpace
    @State private var keepMicWarm = Settings.keepMicWarm

    var body: some View {
        SettingsPage(.dictation) {
            SettingsSection("Input", note: "A Bluetooth headset mic drops the headset to low-quality call audio, so Automatic uses the built-in mic.") {
                SettingRow("Language", "Flow detects German and English per dictation.") {
                    Picker("Language", selection: $language) {
                        Text("Detect automatically").tag("auto")
                        Text("Deutsch").tag("de-DE")
                        Text("English").tag("en-US")
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: language) { Settings.language = language }
                }
                SettingRow("Microphone") {
                    Picker("Microphone", selection: $microphone) {
                        Text("Automatic" + (AudioDevices.resolve("auto").map { " (\($0.name))" } ?? "")).tag("auto")
                        Text("System default").tag("default")
                        Divider()
                        ForEach(AudioDevices.inputs(), id: \.uid) { d in
                            Text(d.name + (d.isBluetooth ? " (Bluetooth)" : "")).tag(d.uid)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: microphone) { actions.setMicrophone(microphone) }
                }
            }
            SettingsSection("Text", note: "A ready mic starts the next dictation at once. The orange mic indicator stays on a little longer.") {
                SettingToggle("Add a space after the text", "So the next dictation doesn't run into this one.", isOn: $trailingSpace)
                    .onChange(of: trailingSpace) { Settings.trailingSpace = trailingSpace }
                SettingToggle("Keep the mic ready for 30 s", "No clipped first word when you dictate in quick succession.", isOn: $keepMicWarm)
                    .onChange(of: keepMicWarm) { actions.setKeepMicWarm(keepMicWarm) }
            }
        }
    }
}

private struct TranscriptionPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var cancelEcho = Settings.cancelEcho

    var body: some View {
        let _ = model.shortcutsRevision
        SettingsPage(.transcription) {
            SettingsSection(note: "Always get consent when transcribing others.") {
                SettingRow(model.transcribing ? "Transcribing" : "Meeting transcription",
                           "\(ShortcutHints.transcribe) to start or stop. You: your mic. Them: what your Mac plays.") {
                    Button(model.transcribing ? "Stop" : "Start", action: actions.toggleTranscription).buttonStyle(.primaryCompact)
                }
                SettingRow("Transcripts folder", model.transcriptsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    HStack(spacing: Space.s4) {
                        Button("Change ›", action: actions.chooseTranscriptsFolder)
                        Button("Open ↗", action: actions.openTranscripts)
                    }
                    .buttonStyle(.monoLink)
                }
            }
            SettingsSection("Audio", note: "On speakers your mic also hears the other side. This removes the speaker audio from your mic. Headphones don't need it.") {
                SettingToggle("Cancel speaker echo", isOn: $cancelEcho)
                    .onChange(of: cancelEcho) { Settings.cancelEcho = cancelEcho }
            }
        }
    }
}

/// The states `--render settings-general*` can show: the totals, the models and the permissions differ.
enum RenderState { case normal, fresh, cleanupOff }

/// The window's content for the offscreen renderer (`--render settings-general`): a running app, no ASR.
@MainActor func mainViewForRender(page: AppModel.Page, vocabulary file: URL? = nil, query: String = "", category: String? = nil,
                                  state: RenderState = .normal) -> some View {
    Settings.registerDefaults()
    let model = AppModel()
    model.page = page
    model.status = state == .fresh ? "ASR: downloading models" : "ASR: ready"
    model.hotkeyActive = state != .fresh
    let fake = FakeModelStore(installed: state == .normal ? [.speech, .cleanup] : state == .cleanupOff ? [.speech] : [])
    let models = ModelSetupModel(store: fake)
    if state == .fresh {
        models.start(.speech)  // sits at 40 % (the fake holds it)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    let sweeper = VaultSweeper()
    let store = VocabularyStore(url: file ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ionian-flow-render.md"), watch: false)
    let actions = AppActions(
        toggleTranscription: {}, reloadEngine: {}, chooseTranscriptsFolder: {}, openTranscripts: {},
        setMicrophone: { _ in }, setKeepMicWarm: { _ in }, applyShortcuts: {}, showSetupGuide: {},
        models: models,
        vocabulary: VocabularyActions(connect: { _ in }, chooseFolder: {}, disconnect: {}, rescan: {}, setUseVocabulary: { _ in }))
    return MainView(model: model, store: store, sweeper: sweeper, actions: actions, query: query, category: category)
}
