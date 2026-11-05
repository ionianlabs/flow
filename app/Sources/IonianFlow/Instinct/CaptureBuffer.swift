import Foundation

/// Short-lived store of delivered dictations: `buffer.jsonl` in the Instinct folder (spec F1.1, F1.5 to F1.8).
final class CaptureBuffer {
    struct Entry: Codable, Equatable {
        var id: String
        var time: Date
        var app: String
        var bundle: String
        var text: String
    }

    static let maxAge: TimeInterval = 24 * 3600
    static let maxBytes = 1_048_576

    private let folder: URL
    private let file: URL
    private let now: () -> Date
    private let log: (String) -> Void
    private var loggedBad = Set<String>()
    private let lock = NSLock()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISO8601DateFormatter().string(from: date))
        }
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad time")
            }
            return date
        }
        return d
    }()

    init(folder: URL, now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.folder = folder
        self.file = folder.appendingPathComponent("buffer.jsonl")
        self.now = now
        self.log = log
    }

    /// Adds one dictation. Drops lines older than 24 h, then the oldest lines until the new one fits in 1 MB.
    /// Returns nil when the line alone is larger than the limit (nothing is stored then).
    @discardableResult
    func append(text: String, app: String, bundle: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(id: UUID().uuidString, time: now(), app: app, bundle: bundle, text: text)
        guard let line = try? encoder.encode(entry), line.count + 1 <= Self.maxBytes else { return nil }
        var entries = loadFresh()
        var total = (entries.compactMap { try? encoder.encode($0).count + 1 }).reduce(0, +) + line.count + 1
        while total > Self.maxBytes, !entries.isEmpty {
            total -= ((try? encoder.encode(entries.removeFirst()).count) ?? 0) + 1
        }
        entries.append(entry)
        write(entries)
        return entry
    }

    func read() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let (all, fresh) = parse()
        if fresh.count != all { write(fresh) }
        return fresh
    }

    func remove(ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let kept = loadFresh()
        let left = kept.filter { !ids.contains($0.id) }
        if left.count != kept.count { write(left) }
    }

    // MARK: private

    /// Parsed entries from the file within 24 h; `all` counts every line (good or bad, old or new) so callers know whether to rewrite.
    private func parse() -> (all: Int, fresh: [Entry]) {
        guard let data = try? Data(contentsOf: file), let raw = String(data: data, encoding: .utf8) else { return (0, []) }
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        var all = 0
        var fresh: [Entry] = []
        for sub in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            all += 1
            let line = String(sub)
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) else {
                if loggedBad.insert(line).inserted { log("Instinct: skipped an unreadable line in buffer.jsonl") }
                continue
            }
            if entry.time >= cutoff { fresh.append(entry) }
        }
        return (all, fresh)
    }

    private func loadFresh() -> [Entry] { parse().fresh }

    private func write(_ entries: [Entry]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var data = Data()
        for e in entries { if let l = try? encoder.encode(e) { data.append(l); data.append(0x0A) } }
        let tmp = folder.appendingPathComponent("buffer.jsonl.tmp")
        fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? fm.replaceItemAt(file, withItemAt: tmp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
