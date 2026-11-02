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
    @Published var status = "ASR: starting"
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
    var restartASR: () -> Void
    var openLog: () -> Void
    var chooseTranscriptsFolder: () -> Void
    var openTranscripts: () -> Void
    var setMicrophone: (String) -> Void
    var setKeepMicWarm: (Bool) -> Void
    var applyShortcuts: () -> Void
    var showSetupGuide: () -> Void
    var vocabulary: VocabularyActions
}

/// The Ionian Flow window: settings and the vocabulary, one page each, in Ionian Flow's own look (see
/// Theme.swift) inside a regular macOS window with a native sidebar and grouped forms. While it's open Ionian Flow is a regular app (Dock,
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

    /// The speech model's state as a dot with its word (MAC-09).
    var recognizerStatus: StatusDot {
        if recognizerReady { return StatusDot(state: .ready, word: "Ready") }
        let text = status.replacingOccurrences(of: "ASR: ", with: "").replacingOccurrences(of: "ASR ", with: "Speech model ")
            .replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        return StatusDot(state: status.hasPrefix("Grant") ? .off : .working, word: text.capitalizingFirst)
    }
}

private struct MainView: View {
    @ObservedObject var model: AppModel
    var store: VocabularyStore
    @ObservedObject var sweeper: VaultSweeper
    var actions: AppActions

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, sweeper: sweeper)
                .navigationSplitViewColumnWidth(min: 180, ideal: WindowLayout.sidebar, max: 280)
        } detail: {
            Group {
                switch model.page {
                case .general: SettingsForm { GeneralPage(model: model, actions: actions) }
                case .shortcuts: SettingsForm { ShortcutsPage(model: model, actions: actions) }
                case .dictation: SettingsForm { DictationPage(actions: actions) }
                case .transcription: SettingsForm { TranscriptionPage(model: model, actions: actions) }
                case .vocabulary:
                    GeometryReader { geo in
                        VocabularyPage(store: store, sweeper: sweeper, actions: actions.vocabulary)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.bg)
                }
            }
            .navigationTitle(model.page.rawValue)
        }
        .tint(Color.accent)
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
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some View {
        List(selection: Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
            ForEach(AppModel.Page.allCases) { page in
                HStack {
                    Label(page.rawValue, systemImage: page.symbol)
                    if page == .vocabulary && sweeper.running {
                        Spacer()
                        ProgressView().controlSize(.mini)
                    }
                }
                .tag(page)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Lockup().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if model.transcribing { StatusLabel(model.transcribingStatus) }
                StatusLabel(model.recognizerStatus)
                Text("On this Mac · \(version)").font(.footnote).foregroundStyle(.tertiary)
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

extension AppModel {
    var transcribingStatus: StatusDot { StatusDot(state: .working, word: "Transcribing") }
}

/// A settings page: a native grouped form.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }.formStyle(.grouped)
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var sounds = Settings.sounds
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        StatsSection(model: model)
        HowToSection(model: model, actions: actions)
        Section("Speech model") {
            LabeledContent {
                HStack(spacing: 12) {
                    StatusLabel(model.recognizerStatus)
                    Button("Restart", action: actions.restartASR)
                    Button("Open Log", action: actions.openLog)
                }
            } label: {
                SettingLabel("Recognizer", "NVIDIA Nemotron, on this Mac's GPU. Nothing goes to the cloud.")
            }
        }
        Section("App") {
            LabeledContent {
                Button("Open", action: actions.showSetupGuide)
            } label: {
                SettingLabel("Setup guide", "Permissions, your dictation key and a field to try it.")
            }
            Toggle(isOn: $sounds) { SettingLabel("Sounds", "A short sound when dictation starts and ends.") }
                .onChange(of: sounds) { Settings.sounds = sounds }
            Toggle("Launch at login", isOn: $login)
                .onChange(of: login) {
                    do {
                        if login { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("Ionian Flow: launch at login failed: %@", error.localizedDescription)
                        login = SMAppService.mainApp.status == .enabled
                    }
                }
        }
    }
}

/// What Flow has done for you so far: words dictated, meetings transcribed, typing time saved.
private struct StatsSection: View {
    @ObservedObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        let _ = model.statsRevision
        let empty = Stats.words == 0 && Stats.transcribedSeconds == 0
        Section {
            LabeledContent("Words dictated", value: Stats.words.formatted())
            LabeledContent("Meetings transcribed", value: Self.duration(Stats.transcribedSeconds))
            LabeledContent("Saved over typing", value: (Stats.savedSeconds >= 60 ? "≈ " : "") + Self.duration(Stats.savedSeconds))
        } header: {
            HStack {
                Text("So far")
                Spacer()
                if !empty { Button("Reset…") { confirmReset = true }.buttonStyle(.link).textCase(nil) }
            }
        } footer: {
            if empty { Text("Your first dictation starts the count. Flow keeps only the totals, never the text.") }
        }
        .confirmationDialog("Reset the totals to zero.", isPresented: $confirmReset) {
            Button("Reset") {
                Stats.reset()
                model.statsRevision += 1
            }
        }
    }

    /// "0 min", "42 min", "3 h", "6 h 40 min".
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60, h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(minutes) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

/// How it works, in three steps: hold your key, talk, let go. The other two keys sit below.
private struct HowToSection: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    /// The wave visual is 52 pt tall, the pill's wave is 30.
    private static let waveScale: CGFloat = 52 / 30
    private static let visualHeight: CGFloat = 64

    var body: some View {
        let _ = model.shortcutsRevision
        let key = Settings.dictationKey
        if !model.hotkeyActive {
            Section {
                LabeledContent {
                    Button("Open Setup Guide", action: actions.showSetupGuide)
                } label: {
                    Text("Keys need permissions.")
                }
            }
        }
        Section("How it works") {
            HStack(alignment: .top, spacing: 20) {
                step("Hold the key", "Hold \(key.name) wherever you can type.") {
                    Key(label: key.keyLabel, size: key == .fn ? 16 : 24, held: true).scaleEffect(0.8, anchor: .leading)
                }
                step("Speak", "Talk as you would to a colleague.") {
                    Wave(bars: 11, scale: Self.waveScale)
                }
                step("Let go", "Clean text appears at your cursor.") {
                    Text("The launch moves to Thursday.")
                        .padding(.leading, 10).padding(.vertical, 2)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.accent).frame(width: 2) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            LabeledContent("Transcribe a meeting") {
                KeyChip(Settings.transcriptionShortcut?.display ?? "Double-tap \(key.name)")
            }
            LabeledContent("Cancel while dictating") { KeyChip(Settings.cancelShortcut.display) }
        }
    }

    private func step<V: View>(_ title: String, _ text: String, @ViewBuilder visual: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            visual().frame(height: Self.visualHeight, alignment: .leading)
            Text(title).font(.headline).padding(.top, 6)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Section {
            Picker(selection: $key) {
                ForEach(DictationKey.allCases) { Text($0.name).tag($0) }
            } label: {
                SettingLabel("Dictate", "Hold this key while you talk.")
            }
            .onChange(of: key) { Settings.dictationKey = key; actions.applyShortcuts() }
            LabeledContent {
                ShortcutRecorder(shortcut: $transcription, placeholder: "Double-tap \(key.name)") {
                    Settings.transcriptionShortcut = transcription
                    actions.applyShortcuts()
                }
            } label: {
                SettingLabel("Transcribe a meeting", "Opens the transcript panel. The same keys stop it.")
            }
            LabeledContent {
                ShortcutRecorder(shortcut: $handsFree, placeholder: "Menu bar only") {
                    Settings.handsFreeShortcut = handsFree
                    actions.applyShortcuts()
                }
            } label: {
                SettingLabel("Hands-free dictation", "Dictate without holding a key. Tap the key to finish.")
            }
            LabeledContent {
                ShortcutRecorder(shortcut: $cancel, placeholder: "Esc", requireModifier: false) {
                    Settings.cancelShortcut = cancel ?? .escape
                    actions.applyShortcuts()
                }
            } label: {
                SettingLabel("Cancel a dictation", "Nothing is pasted.")
            }
        } footer: {
            if model.hotkeyActive {
                Text("Click a shortcut, then press the keys. Combinations need ⌘, ⌥ or ⌃.")
            } else {
                Text("Shortcuts don't work yet. Allow Input Monitoring and Accessibility, then restart Flow.")
                    .foregroundStyle(.primary)
            }
        }
        if !model.hotkeyActive {
            Section { Button("Open Setup Guide", action: actions.showSetupGuide) }
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
        Section {
            Picker(selection: $language) {
                Text("Detect automatically").tag("auto")
                Text("Deutsch").tag("de-DE")
                Text("English").tag("en-US")
            } label: {
                SettingLabel("Language", "Flow detects German and English per dictation.")
            }
            .onChange(of: language) { Settings.language = language }
            Picker("Microphone", selection: $microphone) {
                Text("Automatic" + (AudioDevices.resolve("auto").map { " (\($0.name))" } ?? "")).tag("auto")
                Text("System default").tag("default")
                Divider()
                ForEach(AudioDevices.inputs(), id: \.uid) { d in
                    Text(d.name + (d.isBluetooth ? " (Bluetooth)" : "")).tag(d.uid)
                }
            }
            .onChange(of: microphone) { actions.setMicrophone(microphone) }
        } header: {
            Text("Input")
        } footer: {
            Text("A Bluetooth headset mic drops the headset to low-quality call audio, so Automatic uses the built-in mic.")
        }
        Section {
            Toggle(isOn: $trailingSpace) { SettingLabel("Add a space after the text", "So the next dictation doesn't run into this one.") }
                .onChange(of: trailingSpace) { Settings.trailingSpace = trailingSpace }
            Toggle(isOn: $keepMicWarm) { SettingLabel("Keep the mic ready for 30 s", "No clipped first word when you dictate in quick succession.") }
                .onChange(of: keepMicWarm) { actions.setKeepMicWarm(keepMicWarm) }
        } header: {
            Text("Text")
        } footer: {
            Text("A ready mic starts the next dictation at once. The orange mic indicator stays on a little longer.")
        }
    }
}

private struct TranscriptionPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var cancelEcho = Settings.cancelEcho

    var body: some View {
        let _ = model.shortcutsRevision
        Section {
            LabeledContent {
                Button(model.transcribing ? "Stop" : "Start", action: actions.toggleTranscription)
                    .buttonStyle(.borderedProminent)
            } label: {
                SettingLabel(model.transcribing ? "Transcribing" : "Meeting transcription",
                             "\(ShortcutHints.transcribe) to start or stop. You: your mic. Them: what your Mac plays.")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Change…", action: actions.chooseTranscriptsFolder)
                    Button("Open", action: actions.openTranscripts)
                }
            } label: {
                SettingLabel("Transcripts folder", model.transcriptsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
        } footer: {
            Text("Always get consent when transcribing others.")
        }
        Section {
            Toggle("Cancel speaker echo", isOn: $cancelEcho)
                .onChange(of: cancelEcho) { Settings.cancelEcho = cancelEcho }
        } header: {
            Text("Audio")
        } footer: {
            Text("On speakers your mic also hears the other side. This removes the speaker audio from your mic. Headphones don't need it.")
        }
    }
}

/// The window's content for the offscreen renderer (`--render settings-general`): a running app, no ASR.
@MainActor func mainViewForRender(page: AppModel.Page, vocabulary file: URL? = nil) -> some View {
    Settings.registerDefaults()
    let model = AppModel()
    model.page = page
    model.status = "ASR: ready"
    model.hotkeyActive = true
    let sweeper = VaultSweeper(asrDir: "")
    let store = VocabularyStore(url: file ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ionian-flow-render.md"), watch: false)
    let actions = AppActions(
        toggleTranscription: {}, restartASR: {}, openLog: {}, chooseTranscriptsFolder: {}, openTranscripts: {},
        setMicrophone: { _ in }, setKeepMicWarm: { _ in }, applyShortcuts: {}, showSetupGuide: {},
        vocabulary: VocabularyActions(connect: { _ in }, chooseFolder: {}, disconnect: {}, rescan: {}, setUseVocabulary: { _ in }))
    return MainView(model: model, store: store, sweeper: sweeper, actions: actions)
}
