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
/// Theme.swift) inside a regular macOS window. While it's open Ionian Flow is a regular app (Dock,
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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = IonianColor.bg
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
        HStack(spacing: 0) {
            Sidebar(model: model, sweeper: sweeper)
            Group {
                switch model.page {
                case .general: PageScroll(page: .general) { GeneralPage(model: model, actions: actions) }
                case .shortcuts: PageScroll(page: .shortcuts) { ShortcutsGroup(model: model, actions: actions) }
                case .dictation: PageScroll(page: .dictation) { DictationPage(actions: actions) }
                case .transcription: PageScroll(page: .transcription) { TranscriptionPage(model: model, actions: actions) }
                case .vocabulary: VocabularyPage(store: store, sweeper: sweeper, actions: actions.vocabulary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bg)
        }
        .ignoresSafeArea()
        .tint(Color.btnBg)
    }
}

/// The lockup, the pages (⌘1–⌘5), and at the bottom whether the speech model is ready (MAC-03, MAC-04).
private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sweeper: VaultSweeper
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Lockup()
                .padding(.leading, Space.s6)
                .padding(.top, Space.s8)
                .padding(.bottom, Space.s7)
            VStack(alignment: .leading, spacing: Space.s1) {
                ForEach(Array(AppModel.Page.allCases.enumerated()), id: \.element) { i, page in
                    NavItem(page: page, selected: model.page == page, busy: page == .vocabulary && sweeper.running) {
                        model.page = page
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
            .padding(.horizontal, Space.s6)
            Spacer()
            VStack(alignment: .leading, spacing: Space.s2) {
                if model.transcribing { StatusDot(state: .working, word: "Transcribing") }
                model.recognizerStatus
                MonoLabel("On this Mac · \(version)")
            }
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s5)
        }
        .frame(width: WindowLayout.sidebar)
        .frame(maxHeight: .infinity)
        .background(Color.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.line).frame(width: 1) }
    }
}

/// Text only: ink and medium when selected, muted otherwise. No fill, box or border (MAC-04).
private struct NavItem: View {
    let page: AppModel.Page
    let selected: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s2) {
                Text(page.rawValue)
                    .ionianText(IonianType.small, weight: selected ? 500 : 400)
                    .foregroundStyle(selected || hovering ? Color.ink : Color.muted)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.mini) }
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A settings page: its headline, then groups, scrolling when the window is short.
private enum PageGap { static let value = Space.s7 }

private struct PageScroll<Content: View>: View {
    let page: AppModel.Page
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageGap.value) {
                PageHead(title: page.title, lead: page.subtitle)
                    .frame(maxWidth: WindowLayout.lead, alignment: .leading)  // about 65 characters of the lead
                content
            }
            .frame(maxWidth: WindowLayout.content, alignment: .leading)
            .padding(.horizontal, Space.s7)
            .padding(.top, Space.s8)
            .padding(.bottom, Space.s7)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var sounds = Settings.sounds
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: PageGap.value) {
            StatsCard(model: model)
            HowToSteps(model: model, actions: actions)
            SettingsGroup(title: "Speech model") {
                SettingRow(title: "Recognizer", detail: "NVIDIA Nemotron, on this Mac's GPU. Nothing goes to the cloud.") {
                    HStack(spacing: Space.s4) {
                        model.recognizerStatus
                        Button("Restart ›", action: actions.restartASR).buttonStyle(.monoLink)
                        Button("Log ↗", action: actions.openLog).buttonStyle(.monoLink)
                    }
                }
            }
            SettingsGroup(title: "App") {
                SettingRow(title: "Setup guide", detail: "Permissions, your dictation key and a field to try it.") {
                    Button("Open ›", action: actions.showSetupGuide).buttonStyle(.monoLink)
                }
                SettingRow(title: "Sounds", detail: "A short sound when dictation starts and ends.") {
                    Toggle("Sounds", isOn: $sounds).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: sounds) { Settings.sounds = sounds }
                }
                SettingRow(title: "Launch at login") {
                    Toggle("Launch at login", isOn: $login).labelsHidden().toggleStyle(.switch).controlSize(.small)
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
    }
}

/// What Flow has done for you so far, as hairline-separated facts (feature-grid): words dictated,
/// meetings transcribed, typing time saved. Numerals are solid ink (COL-03).
private struct StatsCard: View {
    @ObservedObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        let _ = model.statsRevision
        let empty = Stats.words == 0 && Stats.transcribedSeconds == 0
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                MonoLabel("So far")
                Spacer()
                if !empty {
                    Button("Reset ›") { confirmReset = true }.buttonStyle(.monoLink)
                }
            }
            VStack(spacing: 0) {
                Hairline()
                HStack(alignment: .top, spacing: 0) {
                    fact(Stats.words.formatted(), "words dictated", first: true)
                    Rectangle().fill(Color.line).frame(width: 1)
                    fact(Self.duration(Stats.transcribedSeconds), "of meetings transcribed")
                    Rectangle().fill(Color.line).frame(width: 1)
                    fact((Stats.savedSeconds >= 60 ? "≈ " : "") + Self.duration(Stats.savedSeconds), "saved over typing")
                }
                .fixedSize(horizontal: false, vertical: true)
                Hairline()
            }
            if empty {
                Text("Your first dictation starts the count. Flow keeps only the totals, never the text.")
                    .ionianText(IonianType.small).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Reset the totals to zero.", isPresented: $confirmReset) {
            Button("Reset") {
                Stats.reset()
                model.statsRevision += 1
            }
        }
    }

    private func fact(_ value: String, _ label: String, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(value).ionianText(IonianType.card).foregroundStyle(Color.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).ionianText(IonianType.small).foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, first ? 0 : Space.s4)
        .padding(.trailing, Space.s2)
        .padding(.vertical, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "0 min", "42 min", "3 h", "6 h 40 min".
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60, h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(minutes) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

/// How it works, in three steps (STE-01..08): hold your key, talk, let go. The other two keys sit below.
private struct HowToSteps: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    /// The wave visual is 52 pt tall (STE visual slot), the pill's wave is 30.
    private static let waveScale: CGFloat = 52 / 30
    private static let visualHeight: CGFloat = 92
    /// `type.title` with a tight line height, so a step heading that wraps stays together.
    private static let stepTitle = IonianTextStyle(family: .display, size: IonianType.title.size, weight: IonianType.title.weight,
                                                    lineHeight: 1.15, tracking: IonianType.title.tracking, uppercase: false)

    var body: some View {
        let _ = model.shortcutsRevision
        let key = Settings.dictationKey
        VStack(alignment: .leading, spacing: Space.s6) {
            if !model.hotkeyActive {
                HStack(spacing: Space.s3) {
                    Text("Keys need permissions.").ionianText(IonianType.small).foregroundStyle(Color.ink)
                    Button("Open the setup guide ›", action: actions.showSetupGuide).buttonStyle(.monoLink)
                }
            }
            HStack(alignment: .top, spacing: Space.s6) {
                step(1, title: "Hold the key", text: "Hold \(key.name) wherever you can type.") {
                    Key(label: key.keyLabel, size: key == .fn ? 16 : 24, held: true)
                }
                step(2, title: "Speak", text: "Talk as you would to a colleague.") {
                    Wave(bars: 11, scale: Self.waveScale)
                }
                step(3, title: "Let go", text: "Clean text appears at your cursor.") {
                    Text("The launch moves to Thursday.").ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .padding(.leading, Space.s4).padding(.vertical, Space.s1)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.accent).frame(width: 2) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                Hairline()
                extra(Settings.transcriptionShortcut?.display ?? "Double-tap \(key.name)", "Transcribe a meeting. Saved as Markdown.")
                Hairline()
                extra(Settings.cancelShortcut.display, "Cancel while dictating. Nothing is pasted.")
                Hairline()
            }
        }
    }

    private func step<V: View>(_ n: Int, title: String, text: String, @ViewBuilder visual: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").ionianText(.init(family: .mono, size: 12, weight: 400, lineHeight: 1.55, tracking: 0, uppercase: false))
                .foregroundStyle(Color.faint)
            visual()
                .frame(height: Self.visualHeight, alignment: .leading)
                .padding(.top, Space.s5)
            Text(title).ionianText(Self.stepTitle).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s5)
            Text(text).ionianText(IonianType.small).foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s2)
        }
        .padding(.top, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }

    private func extra(_ keys: String, _ text: String) -> some View {
        HStack(spacing: Space.s3) {
            KeyChip(keys)
            Text(text).ionianText(IonianType.small).foregroundStyle(Color.muted)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s3)
    }
}

private struct ShortcutsGroup: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var key = Settings.dictationKey
    @State private var transcription = Settings.transcriptionShortcut
    @State private var handsFree = Settings.handsFreeShortcut
    @State private var cancel: Shortcut? = Settings.cancelShortcut == .escape ? nil : Settings.cancelShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            SettingsGroup(
                footer: model.hotkeyActive ? "Click a shortcut, then press the keys. Combinations need ⌘, ⌥ or ⌃."
                    : "Shortcuts don't work yet. Allow Input Monitoring and Accessibility, then restart Flow.",
                footerStyle: model.hotkeyActive ? nil : Color.ink
            ) {
                SettingRow(title: "Dictate", detail: "Hold this key while you talk.") {
                    Picker("Dictate", selection: $key) {
                        ForEach(DictationKey.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: key) { Settings.dictationKey = key; actions.applyShortcuts() }
                }
                SettingRow(title: "Transcribe a meeting", detail: "Opens the transcript panel. The same keys stop it.") {
                    ShortcutRecorder(shortcut: $transcription, placeholder: "Double-tap \(key.name)") {
                        Settings.transcriptionShortcut = transcription
                        actions.applyShortcuts()
                    }
                }
                SettingRow(title: "Hands-free dictation", detail: "Dictate without holding a key. Tap the key to finish.") {
                    ShortcutRecorder(shortcut: $handsFree, placeholder: "Menu bar only") {
                        Settings.handsFreeShortcut = handsFree
                        actions.applyShortcuts()
                    }
                }
                SettingRow(title: "Cancel a dictation", detail: "Nothing is pasted.") {
                    ShortcutRecorder(shortcut: $cancel, placeholder: "Esc", requireModifier: false) {
                        Settings.cancelShortcut = cancel ?? .escape
                        actions.applyShortcuts()
                    }
                }
            }
            if !model.hotkeyActive {
                Button("Open the setup guide ›", action: actions.showSetupGuide).buttonStyle(.monoLink)
            }
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
        VStack(alignment: .leading, spacing: PageGap.value) {
            SettingsGroup(
                title: "Input",
                footer: "A Bluetooth headset mic drops the headset to low-quality call audio, so Automatic uses the built-in mic."
            ) {
                SettingRow(title: "Language", detail: "Flow detects German and English per dictation.") {
                    Picker("Language", selection: $language) {
                        Text("Detect automatically").tag("auto")
                        Text("Deutsch").tag("de-DE")
                        Text("English").tag("en-US")
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: language) { Settings.language = language }
                }
                SettingRow(title: "Microphone") {
                    Picker("Microphone", selection: $microphone) {
                        Text("Automatic" + (AudioDevices.resolve("auto").map { " (\($0.name))" } ?? "")).tag("auto")
                        Text("System default").tag("default")
                        Divider()
                        ForEach(AudioDevices.inputs(), id: \.uid) { d in
                            Text(d.name + (d.isBluetooth ? " (Bluetooth)" : "")).tag(d.uid)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                    .onChange(of: microphone) { actions.setMicrophone(microphone) }
                }
            }
            SettingsGroup(
                title: "Text",
                footer: "A ready mic starts the next dictation at once. The orange mic indicator stays on a little longer."
            ) {
                SettingRow(title: "Add a space after the text", detail: "So the next dictation doesn't run into this one.") {
                    Toggle("Add a space", isOn: $trailingSpace).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: trailingSpace) { Settings.trailingSpace = trailingSpace }
                }
                SettingRow(title: "Keep the mic ready for 30 s", detail: "No clipped first word when you dictate in quick succession.") {
                    Toggle("Keep the mic ready", isOn: $keepMicWarm).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: keepMicWarm) { actions.setKeepMicWarm(keepMicWarm) }
                }
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
        VStack(alignment: .leading, spacing: PageGap.value) {
            SettingsGroup(footer: "Always get consent when transcribing others.") {
                SettingRow(title: model.transcribing ? "Transcribing" : "Meeting transcription",
                           detail: "\(ShortcutHints.transcribe) to start or stop. You: your mic. Them: what your Mac plays.") {
                    Button(model.transcribing ? "Stop" : "Start", action: actions.toggleTranscription)
                        .buttonStyle(.primary)
                }
                SettingRow(title: "Transcripts folder",
                           detail: model.transcriptsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    HStack(spacing: Space.s4) {
                        Button("Change ›", action: actions.chooseTranscriptsFolder).buttonStyle(.monoLink)
                        Button("Open ↗", action: actions.openTranscripts).buttonStyle(.monoLink)
                    }
                }
            }
            SettingsGroup(
                title: "Audio",
                footer: "On speakers your mic also hears the other side. This removes the speaker audio from your mic. Headphones don't need it."
            ) {
                SettingRow(title: "Cancel speaker echo") {
                    Toggle("Cancel speaker echo", isOn: $cancelEcho).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: cancelEcho) { Settings.cancelEcho = cancelEcho }
                }
            }
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
