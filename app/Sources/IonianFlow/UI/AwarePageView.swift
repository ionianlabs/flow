import AppKit
import Combine
import SwiftUI

/// What the page reads from the app each time it refreshes.
struct AwareSnapshot {
    var brain: URL?
    var state: AwareState
    var itemsToday: Int
    var now: Date
    /// Finished meetings waiting to be read or recorded as swept.
    var pending = 0
    /// A sweep is running right now (the scheduler's task), shown as a little more movement in the stage.
    var sweeping = false
}

/// What the Aware page can ask the app to do (F3). Settings without a side effect are written by the page itself.
struct AwareActions {
    enum BrainChoice { case accepted, refused }
    var setOn: (Bool) -> Void = { _ in }
    /// Opens the folder panel; nil when the user cancelled.
    var chooseBrain: () -> BrainChoice? = { nil }
    var openInbox: (URL) -> Void = { _ in }
    var sweepNow: () -> Void = {}
    var snapshot: () -> AwareSnapshot = { AwareSnapshot(brain: nil, state: AwareState(), itemsToday: 0, now: Date()) }
}

extension AppModel.Page {
    var awareSymbol: String { "brain" }
}

/// The Aware page: the stage, the switch and what it is doing, the Brain, what it looks for, one action. Without a Brain the top section invites instead of blocking (F3.15).
struct AwareSettingsPage: View {
    @ObservedObject var models: ModelSetupModel
    var actions: AwareActions
    @State private var on = Settings.aware
    @State private var enableStartedAt: Date?
    @State private var reverting = false
    @State private var kinds = Settings.awareKinds
    @State private var refused = false
    @State private var snapshot: AwareSnapshot?
    @FocusState private var inviteFocused: Bool
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private func refresh() {
        snapshot = actions.snapshot()
    }

    var body: some View {
        let snap = snapshot ?? actions.snapshot()
        let page = AwarePageState.make(
            settings: AwarePageSettings(on: on),
            brain: snap.brain, cleanupInstalled: models.phase(.cleanup) == .installed,
            state: snap.state, now: snap.now, itemsToday: snap.itemsToday, pending: snap.pending, sweeping: snap.sweeping)
        SettingsPage(.aware) {
            VStack(alignment: .leading, spacing: Space.s2) {
                AwareStageView(on: page.switchOn, enableStartedAt: enableStartedAt, sweeping: snap.sweeping)
                if !page.switchOn {
                    Text(AwarePage.pitch).ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, Space.s1)
                }
            }
            SettingsSection {
                SettingRow(AwareApp.toggleTitle, AwareApp.toggleDetail) {
                    Toggle(AwareApp.toggleTitle, isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .tint(Color.btnBg)
                }
                if page.invite {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text(AwareApp.noBrainDetail).ionianText(IonianType.small).foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.s4) {
                            Button(AwareApp.getBrainPill) { NSWorkspace.shared.open(AwareApp.getBrainURL) }
                                .buttonStyle(.primaryCompact).focused($inviteFocused)
                            Button(AwareApp.connectBrainTitle, action: chooseBrain).buttonStyle(.monoLink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Space.s1)
                }
                if let problem = page.problem {
                    Text(problem).ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: Space.s6)
                }
                if !page.statusLines.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(page.statusLines.enumerated()), id: \.offset) { i, line in
                            Text(line).ionianText(IonianType.small).foregroundStyle(i == 0 ? Color.ink : Color.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: Space.s6)
                }
            }
            if page.showsActions {
                SettingsSection("Actions") {
                    SettingRow("Read now", page.sweepDetail) {
                        Button(page.sweepTitle) { actions.sweepNow(); refresh() }.buttonStyle(.primaryCompact).disabled(!page.sweepEnabled)
                    }
                }
            }
            SettingsSection("Brain") {
                SettingRow("Folder", page.brainPath ?? AwarePage.noBrainPath) {
                    HStack(spacing: Space.s4) {
                        Button(page.invite ? "Connect ›" : "Change ›", action: chooseBrain)
                        if page.canOpenInbox { Button("Open inbox ↗") { if let b = snap.brain { actions.openInbox(b) } } }
                    }
                    .buttonStyle(.monoLink)
                }
                if refused {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(AwareApp.notABrain).ionianText(IonianType.small).foregroundStyle(Color.ink)
                        Button(AwareApp.getBrainTitle) { NSWorkspace.shared.open(AwareApp.getBrainURL) }.buttonStyle(.monoLink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: Space.s6)
                }
            }
            SettingsSection("What it looks for") {
                ForEach(AwarePage.kindLines, id: \.0) { kind, line in
                    SettingToggle(AwarePage.kindTitles[kind] ?? kind.rawValue, line, isOn: kindBinding(kind))
                }
            }
        }
        .onChange(of: on) {
            if reverting { reverting = false; return }
            if AwareApp.flip(to: on, brainFound: snap.brain != nil) == .invite {
                reverting = true; on = false; inviteFocused = true
                return
            }
            if on { enableStartedAt = Date() } else { enableStartedAt = nil }
            Settings.aware = on; actions.setOn(on); refresh()
        }
        .onReceive(timer) { _ in refresh() }
    }

    private func kindBinding(_ kind: AwareCategory) -> Binding<Bool> {
        Binding(get: { kinds.contains(kind) }, set: {
            if $0 { kinds.insert(kind) } else { kinds.remove(kind) }
            Settings.awareKinds = kinds
        })
    }

    private func chooseBrain() {
        switch actions.chooseBrain() {
        case .accepted: refused = false; refresh()
        case .refused: refused = true
        case nil: break
        }
    }
}
