import AppKit
import SwiftUI

/// The first-run guide: what Ionian Flow does, the permissions it needs (one at a time, each with
/// the reason), the dictation key, optionally a vault to learn words from, and a field to try it.
/// Opens on first launch and from the Ionian Flow window.
final class OnboardingWindow {
    static let size = WindowLayout.setup
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    init(model: AppModel, step: Int = 0, applyShortcuts: @escaping () -> Void,
         connectVault: @escaping (URL) -> Void, pickVaultFolder: @escaping () -> URL?) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to Ionian Flow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = IonianColor.bg
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OnboardingView(
            model: model, step: step, applyShortcuts: applyShortcuts, connectVault: connectVault,
            pickVaultFolder: pickVaultFolder, onDone: { [weak self] in self?.window.close() }
        ))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        // Closing it, done or not, counts: the guide doesn't come back on its own.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Settings.onboarded = true
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== self.window }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var applyShortcuts: () -> Void
    var connectVault: (URL) -> Void
    var pickVaultFolder: () -> URL?
    var onDone: () -> Void
    var knownVaults: [VaultSweeper.Vault]
    @State private var step: Int
    @State private var vault: URL?

    init(model: AppModel, step: Int, applyShortcuts: @escaping () -> Void, connectVault: @escaping (URL) -> Void,
         pickVaultFolder: @escaping () -> URL?, onDone: @escaping () -> Void,
         knownVaults: [VaultSweeper.Vault] = VaultSweeper.knownVaults(), vault: URL? = Settings.vault) {
        self.model = model
        self.applyShortcuts = applyShortcuts
        self.connectVault = connectVault
        self.pickVaultFolder = pickVaultFolder
        self.onDone = onDone
        self.knownVaults = knownVaults
        _step = State(initialValue: step)
        _vault = State(initialValue: vault)
    }
    private let steps = ["Welcome", "Permissions", "Shortcut", "Your words", "Try it"]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: PermissionsStep(model: model)
                case 2: ShortcutStep(applyShortcuts: applyShortcuts)
                case 3: VaultStep(connected: $vault, known: knownVaults, connectVault: connectVault, pickVaultFolder: pickVaultFolder)
                default: TryStep(model: model, back: { step -= 1 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline()
            HStack(spacing: Space.s3) {
                MonoLabel("\(step + 1) / \(steps.count) · \(steps[step])")
                Spacer()
                if step > 0 { Button("‹ Back") { step -= 1 }.buttonStyle(.monoLink) }
                Button(step == steps.count - 1 ? "Done" : step == 0 ? "Start setup" : step == 3 && vault == nil ? "Skip" : "Continue") {
                    if step == steps.count - 1 { onDone() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
                .padding(.leading, Space.s2)
            }
            .padding(.horizontal, Space.s8)
            .padding(.vertical, Space.s4)
            .background(Color.bg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // inside the title bar's safe area
        .background(Color.bg)
        .tint(Color.btnBg)
    }
}

/// Where every step's content sits: the window's margins and a headline in `type.section`.
private struct StepPage<Content: View>: View {
    let title: Text
    var lead: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s7) {
            VStack(alignment: .leading, spacing: Space.s3) {
                title.ionianText(IonianType.section).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                if let lead {
                    Text(lead).ionianText(IonianType.lead).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: WindowLayout.lead, alignment: .leading)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Space.s8)
        .padding(.top, Space.s8)
    }
}

/// The one chrome moment: Breeze (Night swim in dark, CHR-06) under a `bg` fade, solid for the top 44% and clear by 86% (CHR-05),
/// so the words sit on plain `bg` and only the glimpse of chrome at the bottom shows.
private struct WelcomeStep: View {
    @Environment(\.colorScheme) private var scheme
    private static let facts: [(String, String)] = [
        ("Every app", "Anywhere there is a text cursor."),
        ("Private by default", "Transcription runs on your Mac."),
        ("Clean text", "Punctuation added. Filler words removed."),
        ("Your words", "Teach it names and terms once."),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            ChromeStill(name: scheme == .dark ? "night" : "breeze")
                .frame(height: 340)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: Color.fade, location: 0), .init(color: Color.fade, location: 0.44),
                        .init(color: Color.fade.opacity(0.8), location: 0.58), .init(color: Color.fade.opacity(0.15), location: 0.76),
                        .init(color: Color.fade.opacity(0), location: 0.86),
                    ], startPoint: .top, endPoint: .bottom)
                }
            VStack(alignment: .leading, spacing: 0) {
                AppIcon(size: 84)
                Text("Speak. It lands.").ionianText(IonianType.heroProduct).foregroundStyle(Color.ink)
                    .padding(.top, Space.s5)
                Text("Ionian Flow turns your voice into text in any app, in German and English. Hold a key, talk, let go.")
                    .ionianText(IonianType.lead).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: WindowLayout.lead, alignment: .leading)
                    .padding(.top, Space.s3)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s6), GridItem(.flexible())], alignment: .leading, spacing: Space.s4) {
                    ForEach(Self.facts, id: \.0) { fact in
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Hairline().padding(.bottom, Space.s3)
                            Text(fact.0).ionianText(IonianType.card).foregroundStyle(Color.ink)
                            Text(fact.1).ionianText(IonianType.small).foregroundStyle(Color.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, Space.s7)
            }
            .padding(.horizontal, Space.s8)
            .padding(.top, Space.s8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        StepPage(title: Text("Allow it once."), lead: "macOS asks for each one. Ionian Flow uses them only for what is written here.") {
            // Polled: macOS doesn't announce when a permission is granted in System Settings.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: Space.s4) {
                    VStack(spacing: 0) {
                        ForEach(Array(Permission.allCases.enumerated()), id: \.element.id) { i, permission in
                            Hairline()
                            PermissionRow(number: i + 1, permission: permission)
                        }
                        Hairline()
                    }
                    if Permission.inputMonitoring.granted == true && Permission.accessibility.granted == true
                        && !model.hotkeyActive {
                        HStack(spacing: Space.s4) {
                            Text("macOS applies these after a restart of Ionian Flow.")
                                .ionianText(IonianType.small).foregroundStyle(Color.ink)
                            Spacer()
                            Button("Restart ›", action: relaunch).buttonStyle(.monoLink)
                        }
                    }
                }
            }
        }
    }
}

/// A setup-list item (STE-03, STE-06): accent mono numeral, a bold imperative, one plain sentence.
private struct PermissionRow: View {
    let number: Int
    let permission: Permission

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Text("\(number)").ionianText(IonianType.label).foregroundStyle(Color.accent)
                .frame(width: 20, alignment: .leading).padding(.top, Space.s1)
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(permission.action).ionianText(IonianType.small, weight: 600).foregroundStyle(Color.ink)
                Text(permission.reason).ionianText(IonianType.small).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s3)
            VStack(alignment: .trailing, spacing: Space.s1) {
                switch permission.granted {
                case true?:
                    StatusDot(state: .ready, word: "Allowed")
                case false?:
                    StatusDot(state: .off, word: "Not yet")
                    Button("Allow ›") { permission.request() }.buttonStyle(.monoLink)
                case nil:
                    MonoLabel("Optional")
                    Button("Open settings ↗") { permission.openSettings() }.buttonStyle(.monoLink)
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, Space.s3)
    }
}

/// One choice in a radio list: ink text and a 2 pt ink rule when selected, hairlines between rows.
private struct ChoiceRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) { label; Spacer() }
                .padding(.leading, Space.s4)
                .frame(height: 48)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) { Rectangle().fill(Color.ink).frame(width: 2).opacity(selected ? 1 : 0) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ShortcutStep: View {
    var applyShortcuts: () -> Void
    @State private var key = Settings.dictationKey

    var body: some View {
        StepPage(title: Text("Pick your key."),
                 lead: "Hold it while you talk and let go to insert the text. Double-tap it to transcribe a meeting.") {
            VStack(alignment: .leading, spacing: Space.s4) {
                VStack(spacing: 0) {
                    Hairline()
                    ForEach(DictationKey.allCases) { k in
                        ChoiceRow(selected: key == k, action: { key = k }) {
                            KeyChip(k.name)
                            if k == .rightOption { MonoLabel("Recommended") }
                        }
                        Hairline()
                    }
                }
                .onChange(of: key) {
                    Settings.dictationKey = key
                    applyShortcuts()
                }
                if key == .fn {
                    Text("Set the fn key to “Do Nothing” in System Settings, under Keyboard. Otherwise macOS also opens the emoji picker.")
                        .ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Change this and the other shortcuts any time in the Ionian Flow window.")
                    .ionianText(IonianType.small).foregroundStyle(Color.muted)
            }
        }
    }
}

/// Optional: an Obsidian vault (or any Markdown folder) to learn names and acronyms from.
private struct VaultStep: View {
    @Binding var connected: URL?
    let known: [VaultSweeper.Vault]
    var connectVault: (URL) -> Void
    var pickVaultFolder: () -> URL?

    var body: some View {
        StepPage(title: Text("Teach it your words."),
                 lead: "Optional. Connect an Obsidian vault and Ionian Flow learns the names and terms in your notes. "
                    + "The vault is only read. Nothing leaves your Mac.") {
            VStack(alignment: .leading, spacing: Space.s4) {
                VStack(spacing: 0) {
                    Hairline()
                    ForEach(known, id: \.self) { v in
                        ChoiceRow(selected: connected == v.url, action: { connect(v.url) }) {
                            Text(v.name).ionianText(IonianType.small, weight: connected == v.url ? 600 : 400)
                                .foregroundStyle(connected == v.url ? Color.ink : Color.muted)
                        }
                        Hairline()
                    }
                    HStack {
                        Button(known.isEmpty ? "Choose a folder ›" : "Another folder ›") {
                            if let url = pickVaultFolder() { connect(url) }
                        }
                        .buttonStyle(.monoLink)
                        Spacer()
                    }
                    .padding(.leading, Space.s4).frame(height: 48)
                    Hairline()
                }
                if let connected {
                    Text("Connected to \(VaultSweeper.name(of: connected)). The first scan runs in the background "
                         + "and can take a few minutes.")
                        .ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Skip this without Obsidian. Any folder of Markdown notes works too, now or later.")
                        .ionianText(IonianType.small).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func connect(_ url: URL) {
        guard url != connected else { return }
        connectVault(url)
        connected = url
    }
}

private struct TryStep: View {
    @ObservedObject var model: AppModel
    var back: () -> Void
    @State private var text = ""

    /// The key glyph is set in mono: the display face has no ⌥.
    private var headline: Text {
        let hint = ShortcutHints.dictate
        let verb = hint.hasPrefix("Hold ") ? "Hold " : ""
        return Text(verb) + Text(String(hint.dropFirst(verb.count))).font(.ionian(IonianType.code, size: IonianType.section.size))
            + Text(" and talk.")
    }

    var body: some View {
        StepPage(title: headline, lead: "Click into the field first. Your words land there.") {
            VStack(alignment: .leading, spacing: Space.s4) {
                TextEditor(text: $text)
                    .ionianText(IonianType.small)
                    .foregroundStyle(Color.ink)
                    .scrollContentBackground(.hidden)
                    .padding(Space.s3)
                    .frame(height: 130)
                    .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surface))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.line))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Your words appear here.").ionianText(IonianType.small).foregroundStyle(Color.muted)
                                .padding(.horizontal, Space.s4).padding(.vertical, Space.s3).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: Space.s3) {
                    StatusDot(state: model.recognizerReady ? .ready : model.recognizerFailed ? .off : .working,
                              word: model.recognizerReady ? "Ready" : model.recognizerFailed ? "Error" : "Loading models")
                    if model.recognizerFailed {
                        Text("The speech models didn't load. Try Reload in Settings.").ionianText(IonianType.small).foregroundStyle(Color.muted)
                    } else if !model.recognizerReady {
                        Text("The first start takes a moment.").ionianText(IonianType.small).foregroundStyle(Color.muted)
                    }
                }
                if !Permission.allRequiredGranted {
                    HStack(spacing: Space.s3) {
                        Text("Some permissions are missing.").ionianText(IonianType.small).foregroundStyle(Color.ink)
                        Button("Go back ›", action: back).buttonStyle(.monoLink)
                    }
                }
                VStack(alignment: .leading, spacing: Space.s2) {
                    MonoLabel("Good to know")
                    tip(ShortcutHints.transcribe, "starts or stops a meeting transcript.")
                    tip(ShortcutHints.cancel, "cancels a dictation. Nothing is pasted.")
                    tip(nil, "Find settings in the menu bar icon.")
                }
                .padding(.top, Space.s1)
            }
        }
    }

    /// "Double-tap right ⌥" becomes the verb as text and the key as a chip.
    private func tip(_ hint: String?, _ text: String) -> some View {
        let verb = ["Double-tap ", "Hold "].first { hint?.hasPrefix($0) == true }
        return HStack(spacing: Space.s2) {
            if let verb { Text(verb).ionianText(IonianType.small).foregroundStyle(Color.muted) }
            if let hint { KeyChip(String(hint.dropFirst(verb?.count ?? 0))) }
            Text(text).ionianText(IonianType.small).foregroundStyle(Color.muted)
        }
    }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
