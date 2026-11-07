import Foundation

/// What one finished sweep did (F1.40): what the page and the notification say. Counts only, never content.
struct InstinctSweepResult: Codable, Equatable {
    var at: Date
    var meetings: Int
    var dictations: Int
    var written: Int
    var failed = false
    /// The day file that got the proposals.
    var file: String?
}

/// `state.json` in the Instinct folder: when Instinct was turned on, which transcripts are swept, the last sweep.
struct InstinctState: Codable, Equatable {
    var enabledAt: Date?
    var swept: [String] = []
    var lastSweep: Date?
    var lastResult: InstinctSweepResult?

    init(enabledAt: Date? = nil, swept: [String] = [], lastSweep: Date? = nil) {
        self.enabledAt = enabledAt; self.swept = swept; self.lastSweep = lastSweep
    }

    static let fileName = "state.json"

    /// A missing or unreadable file is an empty state.
    static func load(from folder: URL) -> InstinctState {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return InstinctState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(InstinctState.self, from: data)) ?? InstinctState()
    }

    /// Creates the folder if missing; the file has mode 0600 (F1.5).
    func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = folder.appendingPathComponent(Self.fileName)
        try e.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // The encoder omits nil keys; the file always carries the first three.
    enum CodingKeys: String, CodingKey { case enabledAt, swept, lastSweep, lastResult }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabledAt, forKey: .enabledAt)
        try c.encode(swept, forKey: .swept)
        try c.encode(lastSweep, forKey: .lastSweep)
        try c.encodeIfPresent(lastResult, forKey: .lastResult)
    }
}
