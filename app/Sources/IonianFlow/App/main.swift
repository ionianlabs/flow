import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import UserNotifications

IonianFont.register()

if let rc = EngineCLI.run(CommandLine.arguments) { exit(rc) }

if let i = CommandLine.arguments.firstIndex(of: "--vocab-normalize"), CommandLine.arguments.count > i + 2 {
    exit(VocabNormalizer.normalizeFile(vocabulary: CommandLine.arguments[i + 1], input: CommandLine.arguments[i + 2]) ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--wordfreq-zipf"), CommandLine.arguments.count > i + 1 {
    exit(VocabNormalizer.zipfFile(CommandLine.arguments[i + 1]) ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    /// recording: key held (or locked hands-free). tapPending: a short tap that may become a double-tap.
    /// transcribing: transcription mode (double-tap); dictation is off until it stops.
    private enum State {
        case idle, recording(Date, locked: Bool), tapPending, finishing, transcribing
        var isIdle: Bool { if case .idle = self { return true } else { return false } }
    }

    private let engine: SpeechEngine = NativeEngine(finalizer: ParakeetFinalizer())
    private let hotkey = HotkeyMonitor()
    private let audio = AudioCapture()
    private let overlay = OverlayPanel()
    private lazy var transcriber = Transcriber(engine: engine, mic: audio)
    private lazy var transcriptPanel = TranscriptPanel(model: transcriber.model)
    private lazy var vocabulary = VocabularyStore()
    private lazy var sweeper = VaultSweeper()
    private let appModel = AppModel()
    private lazy var mainWindow = MainWindow(model: appModel, store: vocabulary, sweeper: sweeper, actions: AppActions(
        toggleTranscription: { [weak self] in self?.toggleTranscription() },
        reloadEngine: { [weak self] in self?.reloadEngine() },
        chooseTranscriptsFolder: { [weak self] in self?.chooseTranscriptsFolder() },
        openTranscripts: { [weak self] in self?.openTranscripts() },
        setMicrophone: { [weak self] uid in
            Settings.microphone = uid
            self?.audio.shutdown()  // reopen on the new device next time
        },
        setKeepMicWarm: { [weak self] on in
            Settings.keepMicWarm = on
            if !on, case .idle = self?.state { self?.audio.shutdown() }
        },
        applyShortcuts: { [weak self] in self?.applyShortcuts() },
        showSetupGuide: { [weak self] in self?.onboarding.show() },
        models: ModelSetupModel.shared,
        vocabulary: VocabularyActions(
            connect: { [weak self] in self?.connectVault($0) },
            chooseFolder: { [weak self] in self?.chooseVaultFolder() },
            disconnect: { [weak self] in self?.sweeper.disconnect() },
            rescan: { [weak self] in self?.sweeper.scan(requested: true) },
            setUseVocabulary: { [weak self] in self?.setUseVocabulary($0) }
        ),
        aware: awareActions()
    ))
    private var scanWatch: AnyCancellable?
    private var onboardingStep = 0
    private lazy var onboarding = OnboardingWindow(
        model: appModel,
        models: ModelSetupModel.shared,
        step: onboardingStep,
        applyShortcuts: { [weak self] in self?.applyShortcuts() },
        connectVault: { [weak self] in self?.startVault($0) },
        pickVaultFolder: { [weak self] in self?.pickVaultFolder() }
    )

    /// A vault scan pauses whenever Ionian Flow is listening, so it never slows recognition down.
    private var state = State.idle {
        didSet {
            if case .idle = state { sweeper.resume() } else { sweeper.pause() }
            if oldValue.isIdle, !state.isIdle { MainActor.assumeIsolated { aware?.busyStarted() } }
            if !oldValue.isIdle, state.isIdle { MainActor.assumeIsolated { aware?.busyEnded() } }
            if case .transcribing = state { appModel.transcribing = true } else { appModel.transcribing = false }
        }
    }
    /// Aware: built while the setting is on; its tick runs every 10 minutes.
    private var aware: AwareScheduler?
    private var awareTimer: Timer?
    private var session = 0
    /// Engine session of the current dictation; events from older sessions are ignored.
    private var dictation = DictationFlow()
    private var lastTranscribePress: Date?
    /// Keeps the mic open briefly after release: people let go while the last syllable is still trailing.
    private let releaseTail: TimeInterval = 0.3
    private var pendingTail: DispatchWorkItem?
    /// A tap shorter than this is not a dictation; a second press right after it locks hands-free mode.
    private let tapThreshold: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.35
    private var pendingTap: DispatchWorkItem?
    private var history: [String] = []
    private var statusText = "ASR: loading models"
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.registerDefaults()
        setUpMenu()
        setUpEngine()
        ModelSetupModel.shared.onWillRemove = { item in if item == .cleanup { await ModelHub.shared.unload(.gemma) } }
        ModelSetupModel.shared.onChange = { [weak self] in self?.modelsChanged($0) }
        let speechMissing = !ModelSetupModel.shared.canContinue
        if Settings.onboarded {
            AudioCapture.requestPermission { ok in if !ok { NSLog("Ionian Flow: microphone permission denied") } }
            _ = TextInserter.hasAccessibility(prompt: true)
            if speechMissing {  // models were removed or never finished: ask for them instead of failing to start
                onboardingStep = OnboardingView.modelsStep
                onboarding.show()
            }
        } else {
            onboarding.show()  // asks for each permission in turn, with the reason
        }
        startHotkey()

        if speechMissing {
            setStatus("ASR: models not downloaded")  // the engine starts when the download finishes (modelsChanged)
        } else {
            engine.start()
        }
        appModel.cleanupAvailable = engine.capabilities.contains(.polish)
        if FinalPass.downloaded {  // ~80 MB once compiled: transcription can start with it right away
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.transcriber.finalPass.prepare() }
        }

        UNUserNotificationCenter.current().delegate = self
        sweeper.isBusy = { [weak self] in
            guard let self else { return false }
            if case .idle = self.state { return false }
            return true
        }
        sweeper.onFinished = { [weak self] in self?.notifyScanned($0) }
        transcriber.onFinished = { [weak self] in self?.countTranscript() }
        transcriber.onFileFinal = { [weak self] url in MainActor.assumeIsolated { self?.aware?.meetingEnded(url) } }
        awareTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.aware?.tick() }
        }
        if Settings.aware { startAware() }
        sweeper.start()
        // The menu bar icon shows a dot while a scan runs.
        scanWatch = sweeper.$running.receive(on: DispatchQueue.main).sink { [weak self] running in
            self?.statusItem.button?.image = Self.menuBarIcon(badge: running)
        }

        // Scripts and Shortcuts can toggle transcription mode (see README).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.ionian.flow.toggleTranscription"), object: nil, queue: .main
        ) { [weak self] _ in self?.toggleTranscription() }
    }

    /// Opening Ionian Flow again (Spotlight, Finder) while it runs shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        if case .transcribing = state {
            transcriber.stop()
            transcriber.finish()  // no time to wait for the last finals: save what's there
        }
        audio.shutdown()
        engine.stop()
    }

    // MARK: - Hotkey → audio → ASR

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }
        hotkey.onChord = { [weak self] in self?.cancelDictation() }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() }
        hotkey.cancelIsActive = { [weak self] in
            switch self?.state {
            case .recording, .tapPending: return true
            default: return false
            }
        }
        applyShortcuts()
        if hotkey.start() {
            appModel.hotkeyActive = true
        } else {
            // The setup guide asks for it with an explanation; later launches ask directly.
            if Settings.onboarded && !onboarding.isVisible { CGRequestListenEventAccess() }
            setStatus("Grant accessibility and input monitoring")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startHotkey() }
        }
    }

    /// Takes the shortcuts from Settings; called at launch and whenever they change.
    private func applyShortcuts() {
        hotkey.dictationKey = Settings.dictationKey
        hotkey.cancelKey = Settings.cancelShortcut
        var shortcuts: [(Shortcut, () -> Void)] = []
        if let s = Settings.transcriptionShortcut {
            shortcuts.append((s, { [weak self] in self?.transcriptionShortcut() }))
        }
        if let s = Settings.handsFreeShortcut {
            shortcuts.append((s, { [weak self] in self?.handsFreeShortcut() }))
        }
        hotkey.shortcuts = shortcuts
        appModel.shortcutsRevision += 1
    }

    /// Double-tapping the dictation key starts transcription, unless it has its own shortcut.
    private var doubleTapTranscribes: Bool { Settings.transcriptionShortcut == nil }

    private func transcriptionShortcut() {
        switch state {
        case .recording, .tapPending:
            cancelDictation()
            startTranscription()
        case .transcribing:
            stopTranscription()
        case .idle:
            startTranscription()
        case .finishing:
            break
        }
    }

    private func handsFreeShortcut() {
        switch state {
        case .recording(_, locked: true): endDictation()
        case .idle, .finishing: startHandsFree()
        default: break
        }
    }

    private func keyPressed() {
        switch state {
        case .tapPending:  // double-tap: drop the tap's dictation and start transcription mode
            cancelDictation()
            startTranscription()
        case .transcribing:  // double-tap again to stop
            guard doubleTapTranscribes else { return }
            if let last = lastTranscribePress, Date().timeIntervalSince(last) < doubleTapWindow {
                lastTranscribePress = nil
                stopTranscription()
            } else {
                lastTranscribePress = Date()
            }
        case .recording(_, locked: true):  // press again to finish hands-free mode
            endDictation()
        case .recording:
            break
        case .idle, .finishing:
            beginDictation()
        }
    }

    private func keyReleased() {
        guard case .recording(let started, locked: false) = state else { return }
        guard Date().timeIntervalSince(started) >= tapThreshold else {
            guard doubleTapTranscribes else { return cancelDictation() }  // a tap is not a dictation
            state = .tapPending  // keep recording until we know whether a second press follows
            let work = DispatchWorkItem { [weak self] in
                guard let self, case .tapPending = self.state else { return }
                self.cancelDictation()
            }
            pendingTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
            return
        }
        endDictation()
    }

    private func beginDictation() {
        guard engine.isReady else {
            setStatus("ASR: loading models")
            return
        }
        flushTail()
        session += 1
        let id = dictation.begin(engine, language: Settings.language == "auto" ? "" : Settings.language)
        audio.onAudio = { [engine] pcm in engine.push(id, pcm: pcm) }
        audio.onLevel = { [overlay] level in
            DispatchQueue.main.async { overlay.model.level = 0.5 * overlay.model.level + 0.5 * level }  // smooth jitter
        }
        audio.warmSeconds = Settings.keepMicWarm ? 30 : 0
        do {
            try audio.begin(device: AudioDevices.resolve(Settings.microphone))
        } catch {
            NSLog("Ionian Flow: audio start failed: %@", error.localizedDescription)
            dictation.cancel(engine)
            return
        }
        state = .recording(Date(), locked: false)
        overlay.show()
        play("Tink")
    }

    private func endDictation() {
        state = .finishing
        overlay.model.finishing = true
        let tail = DispatchWorkItem { [weak self] in self?.flushTail() }
        pendingTail = tail
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseTail, execute: tail)
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in  // safety net
            guard let self, self.session == id, case .finishing = self.state else { return }
            self.state = .idle
            self.overlay.hide()
        }
    }

    private func startTranscription() {
        guard engine.isReady else {
            setStatus("ASR: loading models")
            return
        }
        flushTail()
        do {
            try transcriber.start()
        } catch {
            NSLog("Ionian Flow: transcription start failed: %@", error.localizedDescription)
            return
        }
        state = .transcribing
        lastTranscribePress = nil
        transcriptPanel.onStop = { [weak self] in self?.stopTranscription() }
        transcriptPanel.show()
        play("Morse")
    }

    /// Adds a finished meeting's length to the General page's total, if anything was said.
    private func countTranscript() {
        let m = transcriber.model
        guard !m.segments.isEmpty, let ended = m.ended else { return }
        Stats.addTranscription(seconds: ended.timeIntervalSince(m.started))
        appModel.statsRevision += 1
    }

    private func stopTranscription() {
        guard case .transcribing = state else { return }
        transcriber.stop()
        state = .idle
        play("Pop")
    }

    /// Stops the post-release tail capture and asks the engine for the final transcript.
    private func flushTail() {
        guard let tail = pendingTail else { return }
        tail.cancel()
        pendingTail = nil
        audio.finish()
        dictation.end(engine)
    }

    private func cancelDictation() {
        switch state {
        case .recording, .tapPending: break
        default: return
        }
        pendingTap?.cancel()
        pendingTap = nil
        audio.finish()
        dictation.cancel(engine)
        state = .idle
        overlay.hide()
    }

    private func setUpEngine() {
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            if self.transcriber.handleMain(event) { return }
            switch event {
            case .ready:
                self.appModel.cleanupAvailable = self.engine.capabilities.contains(.polish)
                self.setStatus("ASR: ready")
            case .partial, .final:
                guard let update = self.dictation.update(for: event) else { return }
                switch update {
                case .partial(let text, let lang):
                    if case .idle = self.state { return }
                    self.overlay.model.update(text)
                    if let lang { self.overlay.model.lang = lang }
                case .final(let text, _):
                    if case .finishing = self.state {
                        self.state = .idle
                        self.overlay.hide()
                    }
                    self.deliver(text)
                }
            case .polished, .summary:
                break
            case .error(let error):
                NSLog("Ionian Flow: speech engine error: %@", String(describing: error))
                if !self.engine.isReady { self.setStatus("ASR: error") }
            }
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else { return }
        play("Pop")
        history.insert(text, at: 0)
        history = Array(history.prefix(10))
        Stats.addDictation(text)
        appModel.statsRevision += 1
        paste(text)
    }

    private func startAware() {
        guard aware == nil else { return }
        let scheduler = MainActor.assumeIsolated { AwareScheduler(
            sweeper: AwareSweepAdapter(build: { AwareApp.liveSweep($0) }), gate: AwareGate(),
            isBusy: { [weak self] in !(self?.state.isIdle ?? true) },
            brainReady: { BrainLocator.current() != nil },
            modelReady: { [weak self] in (self?.engine.capabilities.contains(.polish) ?? false) && AwareApp.makeModel != nil },
            pendingMeetings: { Self.pendingMeetings() }) }
        MainActor.assumeIsolated { scheduler.onFinished = { [weak self] manual in self?.awareSweepEnded(manual: manual) } }
        aware = scheduler
        MainActor.assumeIsolated { scheduler.launch() }
    }

    private func setAware(_ on: Bool) {
        Settings.aware = on
        if on {
            AwareApp.enable(folder: Settings.awareFolder, now: Date())
            startAware()
        } else {
            aware = nil
        }
    }

    @objc private func sweepAwareNow() {
        MainActor.assumeIsolated {
            guard let aware else { return }
            if !aware.sweepNow() {  // F3.16: never drop a click silently
                let why = aware.status ?? "Aware cannot read right now."
                postAwareNotice(AwareApp.Notice(title: why, body: "Open the Aware page for details."), file: nil)
            }
        }
    }

    /// F1.42: transcripts waiting to be read or recorded as swept.
    private static func pendingMeetings() -> Int {
        let p = TranscriptSource.pending(in: Settings.transcriptsFolder, state: AwareState.load(from: Settings.awareFolder))
        return p.toRead.count + p.recordAsSwept.count
    }

    /// F1.40, F1.41: log the counts, notify when there is something to say.
    private func awareSweepEnded(manual: Bool) {
        guard let r = AwareState.load(from: Settings.awareFolder).lastResult else { return }
        NSLog("Ionian Flow: Aware sweep: %d meetings, %d written, failed %d, manual %d",
              r.meetings, r.written, r.failed ? 1 : 0, manual ? 1 : 0)
        if let notice = AwareApp.notice(r, manual: manual) { postAwareNotice(notice, file: r.file) }
    }

    private func postAwareNotice(_ notice: AwareApp.Notice, file: String?) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if let file { content.userInfo = ["file": file] }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "aware", content: content, trigger: nil))
        }
    }

    /// The Aware page: the same actions as the menu items, plus the Brain (F3).
    private func awareActions() -> AwareActions {
        var a = AwareActions()
        a.setOn = { [weak self] in self?.setAware($0) }
        a.chooseBrain = { [weak self] in self?.chooseAwareBrain() }
        a.openInbox = { NSWorkspace.shared.open(AwareApp.inbox(of: $0)) }
        a.sweepNow = { [weak self] in self?.sweepAwareNow() }
        a.snapshot = { [weak self] in
            guard let self else { return AwareSnapshot(brain: nil, state: AwareState(), itemsToday: 0, now: Date()) }
            let now = Date(), brain = BrainLocator.current()
            let items = brain.map { AwareWriter(brainRoot: $0, transcriptsFolder: Settings.transcriptsFolder).itemsToday(on: now) } ?? 0
            let running = MainActor.assumeIsolated { self.aware?.running != nil }
            return AwareSnapshot(brain: brain, state: AwareState.load(from: Settings.awareFolder), itemsToday: items, now: now,
                                 pending: Self.pendingMeetings(), sweeping: running)
        }
        return a
    }

    private func chooseAwareBrain() -> AwareActions.BrainChoice? {
        let panel = NSOpenPanel()
        panel.title = "Ionian Brain"
        panel.message = "Pick the folder of your Ionian Brain."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = BrainLocator.current()
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return AwareApp.chooseBrain(url) { Settings.awareBrainFolder = $0 } ? .accepted : .refused
    }

    private func paste(_ text: String) {
        let needsSpace = Settings.trailingSpace && !(text.last?.isWhitespace ?? true)
        TextInserter.insert(needsSpace ? text + " " : text)
    }

    private func play(_ name: String) {
        guard Settings.sounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }

    // MARK: - Menu bar

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon(badge: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Quick actions only; settings and the vocabulary live in the Ionian Flow window. Rebuilt on every
    /// open so history and status are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: AppModel.statusLine(statusText), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        // A scan or a pending review shows up here, not buried in a submenu.
        if sweeper.running, let vault = Settings.vault {
            var line = "Learning from \(VaultSweeper.name(of: vault))"
            if case .reading(let done, let total) = sweeper.phase, total > 0 { line += " · \(done) of \(total)" }
            menu.addItem(item(line, #selector(openVocabulary)))
        } else if !vocabulary.unreviewed.isEmpty {
            menu.addItem(item("\(vocabulary.unreviewed.count) new \(vocabulary.unreviewed.count == 1 ? "term" : "terms") to review…", #selector(openVocabulary)))
        }
        menu.addItem(.separator())

        if case .transcribing = state {
            menu.addItem(item("Stop transcription", #selector(toggleTranscription)))
        } else {
            menu.addItem(item("Start transcription", #selector(toggleTranscription)))
            menu.addItem(item("Hands-free dictation", #selector(startHandsFree)))
        }
        menu.addItem(.separator())

        if Settings.aware {
            let lines = AwareApp.menuLines(status: MainActor.assumeIsolated { aware?.status })
            if let line = lines.status {
                let status = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                status.isEnabled = false
                menu.addItem(status)
            }
            for title in lines.actions { menu.addItem(item(title, #selector(sweepAwareNow))) }
            menu.addItem(.separator())
        }

        let last = item("Paste last dictation", #selector(pasteHistory(_:)))
        last.tag = 0
        last.isEnabled = !history.isEmpty
        menu.addItem(last)
        if history.count > 1 {
            let recent = NSMenu()
            for (i, text) in history.enumerated() {
                let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                let entry = item(flat.count > 60 ? String(flat.prefix(60)) + "…" : flat, #selector(pasteHistory(_:)))
                entry.tag = i
                entry.toolTip = text
                recent.addItem(entry)
            }
            menu.addItem(submenu("Recent dictations", recent))
        }
        menu.addItem(.separator())

        menu.addItem(item("Vocabulary…", #selector(openVocabulary)))
        let settings = item("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ionian Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    /// Template version of the Flow sign (MAC-14); `badge` adds a dot (a scan is running).
    private static func menuBarIcon(badge: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: FlowSign().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath).fill()
            if badge {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badge ? "Ionian Flow, learning vocabulary" : "Ionian Flow"
        return image
    }

    private func setStatus(_ s: String) {
        statusText = s
        appModel.status = s
        statusItem.button?.appearsDisabled = !engine.isReady
    }

    @objc private func pasteHistory(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        let text = history[sender.tag]
        // let the menu close so focus is back in the target field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.paste(text) }
    }

    @objc private func toggleTranscription() {
        if case .transcribing = state {
            stopTranscription()
        } else if case .idle = state {
            startTranscription()
        }
    }

    /// Dictation without holding the key; a single press of the dictation key finishes it.
    @objc private func startHandsFree() {
        guard case .idle = state else { return }
        beginDictation()
        guard case .recording = state else { return }
        state = .recording(Date(), locked: true)
        overlay.model.locked = true
    }

    @objc private func openSettings() { mainWindow.show(.general) }

    private func openTranscripts() {
        try? FileManager.default.createDirectory(at: Settings.transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.transcriptsFolder)
    }

    private func chooseTranscriptsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Transcripts folder"
        panel.message = "Ionian Flow saves new transcripts here as Markdown."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.transcriptsFolder
        NSApp.activate()  // a menu bar app's panel would otherwise open behind other windows
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.transcriptsFolder = url
        appModel.transcriptsFolder = url
    }

    /// Unloads and loads the speech models again.
    /// A download finished or the cleanup model was removed: capabilities are derived from what is on disk
    /// (NativeEngine.capabilities asks ModelHub.gemmaAvailable), so refreshing is re-reading them. Speech: start the engine.
    private func modelsChanged(_ item: ModelItem) {
        switch item {
        case .speech:
            if ModelSetupModel.shared.canContinue { reloadEngine() }  // emits .ready, which refreshes cleanupAvailable
        case .cleanup:
            appModel.cleanupAvailable = engine.capabilities.contains(.polish)
            if appModel.cleanupAvailable { engine.polish(id: 0, text: "", before: "") }  // preload the model
        }
    }

    private func reloadEngine() {
        setStatus("ASR: loading models")
        engine.stop()
        engine.start()
    }

    // MARK: - Vocabulary

    @objc private func openVocabulary() {
        vocabulary.ensureFile()
        mainWindow.show(.vocabulary)
    }

    private func connectVault(_ url: URL) {
        startVault(url)
        mainWindow.show(.vocabulary)  // the scan's progress shows there
    }

    /// Connects without opening the window, for the setup guide.
    private func startVault(_ url: URL) {
        vocabulary.ensureFile()
        sweeper.connect(url)
    }

    private func chooseVaultFolder() {
        pickVaultFolder().map(connectVault)
    }

    private func pickVaultFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Connect a vault"
        panel.message = "Pick an Obsidian vault or any folder of Markdown notes. Ionian Flow only reads it."
        panel.prompt = "Connect"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private func setUseVocabulary(_ on: Bool) {
        guard on != Settings.useVocabulary else { return }
        Settings.useVocabulary = on
        engine.reloadVocabulary()  // the live bias reads the file at session start; the final pass rebuilds its list
    }

    /// A scan you asked for always reports back; a background resync only when it found something.
    private func notifyScanned(_ r: VaultSweeper.Result) {
        guard let vault = Settings.vault, r.requested || r.added > 0 else { return }
        let name = VaultSweeper.name(of: vault)
        let content = UNMutableNotificationContent()
        if r.first {
            content.title = "Learned \(r.total) terms from \(name)."
        } else if r.added > 0 {
            content.title = "\(r.added) new \(r.added == 1 ? "term" : "terms") from \(name)."
        } else {
            content.title = "Your vocabulary is up to date."
        }
        var body = ["\(r.total) terms"]
        if r.removed > 0 { body.append("\(r.removed) no longer in your notes") }
        body.append(vocabulary.unreviewed.isEmpty ? "Ionian Flow listens for them." : "Open to review the new ones.")
        content.body = body.joined(separator: " · ")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "vocabulary", content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let request = response.notification.request
        DispatchQueue.main.async {
            guard request.identifier == "aware" else { return self.openVocabulary() }
            // The day file with the proposals, else the Aware page.
            if let file = request.content.userInfo["file"] as? String {
                NSWorkspace.shared.open(URL(fileURLWithPath: file))
            } else {
                self.mainWindow.show(.aware)
            }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
}

if CommandLine.arguments.contains("--mictest") {
    runMicTest()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--echotest"), i + 1 < CommandLine.arguments.count {
    runEchoTest(clip: CommandLine.arguments[i + 1])
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--transcribetest") {
    runTranscribeTest(Array(CommandLine.arguments.dropFirst(i + 1)))
}

if CommandLine.arguments.contains("--systemaudiotest") {
    runSystemAudioTest()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--overlay-record") {
    exit(OverlayReplay.record(Array(CommandLine.arguments.dropFirst(i + 1))))
}

if let i = CommandLine.arguments.firstIndex(of: "--overlay-replay") {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated { OverlayReplay.replay(Array(CommandLine.arguments.dropFirst(i + 1))) })
}

if let i = CommandLine.arguments.firstIndex(of: "--render") {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated { Renderer.run(Array(CommandLine.arguments.dropFirst(i + 1))) })
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--demo") {
    runOverlayDemo()
} else if CommandLine.arguments.contains("--transcript-demo") {
    runTranscriptDemo()
} else if let i = CommandLine.arguments.firstIndex(of: "--onboarding-demo") {
    runOnboardingDemo(step: CommandLine.arguments.dropFirst(i + 1).first.flatMap { Int($0) } ?? 0)
} else if let i = CommandLine.arguments.firstIndex(of: "--aware-stage-demo") {
    runAwareStageDemo(mode: CommandLine.arguments.dropFirst(i + 1).first ?? "teaser")
} else if let i = CommandLine.arguments.firstIndex(of: "--vocabulary-demo") {
    runVocabularyDemo(file: CommandLine.arguments.dropFirst(i + 1).first)
} else {
    Migration.run()
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.setActivationPolicy(.accessory)
app.run()

extension AppModel {
    /// The status as one plain word or phrase for the menu: "Ready", "Starting", "Loading model".
    static func statusLine(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "ASR: ", with: "").replacingOccurrences(of: "ASR ", with: "Speech model ")
            .replacingOccurrences(of: "…", with: "")
        return text.capitalizingFirst
    }
}
