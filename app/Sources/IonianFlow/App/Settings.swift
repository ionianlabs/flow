import Foundation

/// User preferences, persisted in UserDefaults and edited from the menu bar.
enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "language": "auto",
            "microphone": "auto",
            "sounds": true,
            "trailingSpace": true,
            "keepMicWarm": false,  // the orange mic dot lingering after dictating looks like spying
            "cancelEcho": true,
            "useVocabulary": true,
            "parakeetFinals": true,
            "summarizeTranscripts": true,
            "instinct": false,
            "instinctExcludedApps": InstinctRules.defaultExcludedApps,
            "instinctIntervalHours": 3,
            "instinctMeetings": true,
            "instinctDictations": true,
        ])
    }

    /// "auto" or a locale the model knows, e.g. "de-DE".
    static var language: String {
        get { d.string(forKey: "language") ?? "auto" }
        set { d.set(newValue, forKey: "language") }
    }

    /// "auto" (system default, but never a Bluetooth headset), "default", or a CoreAudio device UID.
    static var microphone: String {
        get { d.string(forKey: "microphone") ?? "auto" }
        set { d.set(newValue, forKey: "microphone") }
    }

    static var sounds: Bool {
        get { d.bool(forKey: "sounds") }
        set { d.set(newValue, forKey: "sounds") }
    }

    /// Append a space after the pasted text so back-to-back dictations don't run together.
    static var trailingSpace: Bool {
        get { d.bool(forKey: "trailingSpace") }
        set { d.set(newValue, forKey: "trailingSpace") }
    }

    /// Keep the mic open for a while after a dictation: no start-up clipping, plus a short pre-roll.
    static var keepMicWarm: Bool {
        get { d.bool(forKey: "keepMicWarm") }
        set { d.set(newValue, forKey: "keepMicWarm") }
    }

    /// Transcription mode on speakers: remove what the speakers play from the mic signal.
    static var cancelEcho: Bool {
        get { d.bool(forKey: "cancelEcho") }
        set { d.set(newValue, forKey: "cancelEcho") }
    }

    /// Transcription mode's final text from Parakeet (FinalPass) instead of the streaming decoder.
    /// No UI: `defaults write dev.ionian.flow parakeetFinals -bool false` to compare.
    static var parakeetFinals: Bool { d.bool(forKey: "parakeetFinals") }

    /// Frontmatter (description, tags, keywords) and a summary for every finished transcript, by the
    /// cleanup model (needs it downloaded). No UI: `defaults write dev.ionian.flow summarizeTranscripts -bool false`.
    static var summarizeTranscripts: Bool { d.bool(forKey: "summarizeTranscripts") }

    /// Test seam: with IONIAN_FLOW_TEST_DIR set, the vocabulary file, the transcripts folder and the sweep cache
    /// live in that folder, so a CLI test run never reads or writes the user's own files.
    static let testDir: URL? = ProcessInfo.processInfo.environment["IONIAN_FLOW_TEST_DIR"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    static let defaultTranscriptsFolder = testDir?.appendingPathComponent("Transcripts", isDirectory: true)
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Ionian Flow/Transcripts", isDirectory: true)

    /// Where transcription mode writes its Markdown files.
    static var transcriptsFolder: URL {
        get { d.string(forKey: "transcriptsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultTranscriptsFolder }
        set { d.set(newValue.path, forKey: "transcriptsFolder") }
    }

    /// Instinct: propose to-dos, decisions and facts from dictations and meetings to the brain's inbox.
    static var instinct: Bool {
        get { d.bool(forKey: "instinct") }
        set { d.set(newValue, forKey: "instinct") }
    }

    /// Dictations from these apps (bundle ids) are never stored for Instinct.
    static var instinctExcludedApps: [String] {
        get { d.stringArray(forKey: "instinctExcludedApps") ?? InstinctRules.defaultExcludedApps }
        set { d.set(newValue, forKey: "instinctExcludedApps") }
    }

    /// A folder chosen on the Instinct page; tried before the other places a Brain can be (F3.3).
    static var instinctBrainFolder: URL? {
        get { d.string(forKey: "instinctBrainFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { d.set(newValue?.path, forKey: "instinctBrainFolder") }
    }

    /// What Instinct looks for: "todo", "decision", "fact". Default all three (F3.5).
    static var instinctKinds: Set<InstinctCategory> {
        get { InstinctApp.kinds(stored: d.stringArray(forKey: "instinctKinds")) }
        set { d.set(InstinctCategory.allCases.filter(newValue.contains).map(\.rawValue), forKey: "instinctKinds") }
    }

    /// Read finished meetings (F3.6) and dictations (F3.7).
    static var instinctMeetings: Bool {
        get { d.bool(forKey: "instinctMeetings") }
        set { d.set(newValue, forKey: "instinctMeetings") }
    }

    static var instinctDictations: Bool {
        get { d.bool(forKey: "instinctDictations") }
        set { d.set(newValue, forKey: "instinctDictations") }
    }

    static var instinctIntervalHours: Int {
        get { max(d.integer(forKey: "instinctIntervalHours"), 1) }
        set { d.set(newValue, forKey: "instinctIntervalHours") }
    }

    /// "Pause Instinct for 1 hour": nothing is stored and no sweep runs until then.
    static var instinctPausedUntil: Date? {
        get { d.object(forKey: "instinctPausedUntil") as? Date }
        set { d.set(newValue, forKey: "instinctPausedUntil") }
    }

    /// Buffer, state and nothing else of Instinct's own; the proposals go to the brain.
    static var instinctFolder: URL {
        InstinctApp.folder(testDir: testDir, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Names, acronyms and jargon the recognizer should get right (format: see VocabularyParser.swift).
    static let vocabularyFile = testDir?.appendingPathComponent("Vocabulary.md")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Ionian Flow/Vocabulary.md")

    /// Bias the recognizer toward the vocabulary and fix its spellings.
    static var useVocabulary: Bool {
        get { d.bool(forKey: "useVocabulary") }
        set { d.set(newValue, forKey: "useVocabulary") }
    }

    /// The Obsidian vault (or any Markdown folder) the vocabulary is learned from; only ever read.
    static var vault: URL? {
        get { d.string(forKey: "vault").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { d.set(newValue?.path, forKey: "vault") }
    }

    static var lastVaultScan: Date? {
        get { d.object(forKey: "lastVaultScan") as? Date }
        set { d.set(newValue, forKey: "lastVaultScan") }
    }
}

/// Running totals for the General page: two numbers in UserDefaults, never the text itself.
enum Stats {
    private static let d = UserDefaults.standard

    static var words: Int { d.integer(forKey: "statsWords") }
    static var transcribedSeconds: Int { d.integer(forKey: "statsTranscribedSeconds") }
    /// Typing the words at ~40 a minute instead of speaking them at ~150.
    static var savedSeconds: Int { words * 60 / 40 - words * 60 / 150 }

    static func addDictation(_ text: String) {
        d.set(words + text.split(whereSeparator: \.isWhitespace).count, forKey: "statsWords")
    }

    static func addTranscription(seconds: TimeInterval) {
        d.set(transcribedSeconds + Int(seconds.rounded()), forKey: "statsTranscribedSeconds")
    }

    static func reset() {
        d.removeObject(forKey: "statsWords")
        d.removeObject(forKey: "statsTranscribedSeconds")
    }
}
