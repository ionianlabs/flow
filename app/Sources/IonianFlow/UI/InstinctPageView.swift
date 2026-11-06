import AppKit
import Combine
import SwiftUI

/// What the page reads from the app each time it refreshes.
struct InstinctSnapshot {
    var brain: URL?
    var state: InstinctState
    var itemsToday: Int
    var now: Date
    /// A sweep is running right now (the scheduler's task), shown as a little more movement in the stage.
    var sweeping = false
}

/// What the Instinct page can ask the app to do (F3). Settings without a side effect are written by the page itself.
struct InstinctActions {
    enum BrainChoice { case accepted, refused }
    var setOn: (Bool) -> Void = { _ in }
    var setMeetings: (Bool) -> Void = { _ in }
    var setDictations: (Bool) -> Void = { _ in }
    /// Opens the folder panel; nil when the user cancelled.
    var chooseBrain: () -> BrainChoice? = { nil }
    var openInbox: (URL) -> Void = { _ in }
    /// Opens the panel on /Applications and returns the chosen app's bundle id.
    var pickApp: () -> String? = { nil }
    var appName: (String) -> String? = { _ in nil }
    var sweepNow: () -> Void = {}
    var pause: () -> Void = {}
    var snapshot: () -> InstinctSnapshot = { InstinctSnapshot(brain: nil, state: InstinctState(), itemsToday: 0, now: Date()) }
}

extension AppModel.Page {
    var instinctSymbol: String { "brain" }
}

/// The Instinct page: the stage, the switch and what it is doing, the Brain, what it looks for and reads, the apps it
/// ignores, two actions. Without a Brain the top section invites instead of blocking (F3.15).
struct InstinctSettingsPage: View {
    @ObservedObject var models: ModelSetupModel
    var actions: InstinctActions
    @State private var on = Settings.instinct
    @State private var enableStartedAt: Date?
    @State private var reverting = false
    @State private var kinds = Settings.instinctKinds
    @State private var meetings = Settings.instinctMeetings
    @State private var dictations = Settings.instinctDictations
    @State private var hours = Settings.instinctIntervalHours
    @State private var excluded = Settings.instinctExcludedApps
    @State private var refused = false
    @State private var snapshot: InstinctSnapshot?
    @State private var pausedUntil = Settings.instinctPausedUntil
    @FocusState private var inviteFocused: Bool
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private func refresh() {
        snapshot = actions.snapshot()
        pausedUntil = Settings.instinctPausedUntil
    }

    var body: some View {
        let snap = snapshot ?? actions.snapshot()
        let page = InstinctPageState.make(
            settings: InstinctPageSettings(on: on, intervalHours: hours, pausedUntil: pausedUntil),
            brain: snap.brain, cleanupInstalled: models.phase(.cleanup) == .installed,
            state: snap.state, now: snap.now, itemsToday: snap.itemsToday)
        SettingsPage(.instinct) {
            VStack(alignment: .leading, spacing: Space.s2) {
                InstinctStageView(on: page.switchOn, enableStartedAt: enableStartedAt, sweeping: snap.sweeping)
                if !page.switchOn {
                    Text(InstinctPage.pitch).ionianText(IonianType.small).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, Space.s1)
                }
            }
            SettingsSection {
                SettingRow(InstinctApp.toggleTitle, InstinctApp.toggleDetail) {
                    Toggle(InstinctApp.toggleTitle, isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .tint(Color.btnBg)
                }
                if page.invite {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text(InstinctApp.noBrainDetail).ionianText(IonianType.small).foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.s4) {
                            Button(InstinctApp.getBrainPill) { NSWorkspace.shared.open(InstinctApp.getBrainURL) }
                                .buttonStyle(.primaryCompact).focused($inviteFocused)
                            Button(InstinctApp.connectBrainTitle, action: chooseBrain).buttonStyle(.monoLink)
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
                    SettingRow("Read now", InstinctPage.sweepDetail) {
                        Button("Sweep now") { actions.sweepNow(); refresh() }.buttonStyle(.primaryCompact).disabled(!page.canSweep)
                    }
                    SettingRow("Pause", page.pausedLine ?? InstinctPage.pauseDetail) {
                        Button("Pause for 1 hour ›") { actions.pause(); refresh() }.buttonStyle(.monoLink).disabled(!page.canPause)
                    }
                }
            }
            SettingsSection("Brain") {
                SettingRow("Folder", page.brainPath ?? InstinctPage.noBrainPath) {
                    HStack(spacing: Space.s4) {
                        Button(page.invite ? "Connect ›" : "Change ›", action: chooseBrain)
                        if page.canOpenInbox { Button("Open inbox ↗") { if let b = snap.brain { actions.openInbox(b) } } }
                    }
                    .buttonStyle(.monoLink)
                }
                if refused {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(InstinctApp.notABrain).ionianText(IonianType.small).foregroundStyle(Color.ink)
                        Button(InstinctApp.getBrainTitle) { NSWorkspace.shared.open(InstinctApp.getBrainURL) }.buttonStyle(.monoLink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: Space.s6)
                }
            }
            SettingsSection("What it looks for") {
                ForEach(InstinctPage.kindLines, id: \.0) { kind, line in
                    SettingToggle(InstinctPage.kindTitles[kind] ?? kind.rawValue, line, isOn: kindBinding(kind))
                }
            }
            SettingsSection("What it reads") {
                SettingToggle("Meetings", InstinctPage.meetingsDetail, isOn: $meetings)
                    .onChange(of: meetings) { Settings.instinctMeetings = meetings; actions.setMeetings(meetings) }
                SettingRow("Dictations", InstinctPage.dictationsDetail) {
                    HStack(spacing: Space.s3) {
                        Picker("Interval", selection: $hours) {
                            ForEach(InstinctPage.intervals, id: \.self) { Text(InstinctPage.intervalTitle($0)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                        .disabled(!dictations)
                        .onChange(of: hours) { Settings.instinctIntervalHours = hours }
                        Toggle("Dictations", isOn: $dictations).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Color.btnBg)
                            .onChange(of: dictations) { Settings.instinctDictations = dictations; actions.setDictations(dictations) }
                    }
                }
            }
            SettingsSection("Never capture from", note: InstinctPage.excludedNote) {
                ForEach(InstinctPageState.excludedRows(excluded, resolve: actions.appName)) { app in
                    SettingRow(app.name, app.name == app.bundle ? nil : app.bundle) {
                        Button("Remove") { excluded = InstinctRules.removing(app.bundle, from: excluded); Settings.instinctExcludedApps = excluded }
                            .buttonStyle(.monoLink)
                    }
                }
                HStack {
                    Button("Add app +", action: addApp).buttonStyle(.monoLink)
                    Spacer()
                }
                .frame(minHeight: Space.s6)
            }
        }
        .onChange(of: on) {
            if reverting { reverting = false; return }
            if InstinctApp.flip(to: on, brainFound: snap.brain != nil) == .invite {
                reverting = true; on = false; inviteFocused = true
                return
            }
            if on { enableStartedAt = Date() } else { enableStartedAt = nil }
            Settings.instinct = on; actions.setOn(on); refresh()
        }
        .onReceive(timer) { _ in refresh() }
    }

    private func kindBinding(_ kind: InstinctCategory) -> Binding<Bool> {
        Binding(get: { kinds.contains(kind) }, set: {
            if $0 { kinds.insert(kind) } else { kinds.remove(kind) }
            Settings.instinctKinds = kinds
        })
    }

    private func chooseBrain() {
        switch actions.chooseBrain() {
        case .accepted: refused = false; refresh()
        case .refused: refused = true
        case nil: break
        }
    }

    private func addApp() {
        guard let bundle = actions.pickApp() else { return }
        excluded = InstinctRules.adding(bundle, to: excluded)
        Settings.instinctExcludedApps = excluded
    }
}
