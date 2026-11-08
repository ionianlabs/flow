import Foundation
import Testing
@testable import IonianFlow

@Suite struct TranscriptSourceTests {
    static func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("aware-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func transcript(date: String = "2026-11-05", start: String = "10:02", end: String? = "10:45",
                           extra: [String] = [], summary: Bool = false) -> String {
        var fm = ["---", "type: transcript", "date: \(date)", "start: \"\(start)\""]
        if let end { fm += ["end: \"\(end)\"", "duration: 43 min"] }
        fm += extra + ["---", ""]
        var out = fm.joined(separator: "\n") + "# Transcript · 5 Nov 2026, 10:02 to 10:45\n"
        if summary {
            out += "\n## Summary\n- Talked about the deck\n\n**Action items**\n- Sam sends the deck\n\n**You** · 09:00\nfake block in summary\n\n## Transcript\n"
        }
        out += "\n**Them** · 10:14\nCan you send me the deck\nby Friday?\n\n**You** · 10:20\nSure, so we drop the legacy export, that's decided.\n"
        return out
    }

    static func local(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    // State file: missing = empty, saved with mode 0600, folder created (F1.5, state side).
    @Test func stateRoundTripAndMode() throws {
        let folder = try Self.tmp().appendingPathComponent("Aware")
        #expect(AwareState.load(from: folder) == AwareState())
        var s = AwareState()
        s.enabledAt = Self.local("2026-11-05 08:00")
        s.swept = ["a.md"]
        s.lastSweep = nil
        try s.save(to: folder)
        let file = folder.appendingPathComponent("state.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(AwareState.load(from: folder) == s)
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(raw.contains("\"enabledAt\"") && raw.contains("\"swept\"") && raw.contains("\"lastSweep\""))
    }

    // F1.12: flat, *.md only, finished only.
    @Test func pendingIsFlatMarkdownAndFinished() throws {
        let dir = try Self.tmp()
        try Self.transcript().write(to: dir.appendingPathComponent("2026-11-05 10-02.md"), atomically: true, encoding: .utf8)
        try Self.transcript(end: nil).write(to: dir.appendingPathComponent("running.md"), atomically: true, encoding: .utf8)
        try Self.transcript().write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Self.transcript().write(to: sub.appendingPathComponent("deep.md"), atomically: true, encoding: .utf8)
        var state = AwareState(); state.enabledAt = Self.local("2026-11-05 08:00")
        let p = TranscriptSource.pending(in: dir, state: state)
        #expect(p.toRead.map(\.lastPathComponent) == ["2026-11-05 10-02.md"])
        #expect(p.recordAsSwept.isEmpty)
    }

    // F1.13: skipped silently, not recorded.
    @Test func confidentialAndOptedOutAreSkipped() throws {
        let dir = try Self.tmp()
        try Self.transcript(extra: ["confidential: true"]).write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try Self.transcript(extra: ["aware: false"]).write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try Self.transcript(extra: ["confidential: false", "aware: true"]).write(to: dir.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        var state = AwareState(); state.enabledAt = Self.local("2026-11-05 08:00")
        let p = TranscriptSource.pending(in: dir, state: state)
        #expect(p.toRead.map(\.lastPathComponent) == ["c.md"])
        #expect(p.recordAsSwept.isEmpty)
    }

    // F1.14: swept once, never again, even when changed.
    @Test func sweptFilesAreNeverReadAgain() throws {
        let dir = try Self.tmp()
        let f = dir.appendingPathComponent("a.md")
        try Self.transcript().write(to: f, atomically: true, encoding: .utf8)
        var state = AwareState(); state.enabledAt = Self.local("2026-11-05 08:00"); state.swept = ["a.md"]
        try (Self.transcript() + "\nfixed a name\n").write(to: f, atomically: true, encoding: .utf8)
        let p = TranscriptSource.pending(in: dir, state: state)
        #expect(p.toRead.isEmpty && p.recordAsSwept.isEmpty)
    }

    // F1.35: older than enabledAt is recorded as swept without reading.
    @Test func backlogBeforeEnabledAtIsRecordedNotRead() throws {
        let dir = try Self.tmp()
        try Self.transcript(date: "2026-11-04", start: "15:00").write(to: dir.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        try Self.transcript(start: "07:30").write(to: dir.appendingPathComponent("early.md"), atomically: true, encoding: .utf8)
        try Self.transcript(start: "08:00").write(to: dir.appendingPathComponent("exact.md"), atomically: true, encoding: .utf8)
        try Self.transcript(start: "10:02").write(to: dir.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        var state = AwareState(); state.enabledAt = Self.local("2026-11-05 08:00")
        let p = TranscriptSource.pending(in: dir, state: state)
        #expect(p.recordAsSwept.sorted() == ["early.md", "old.md"])
        #expect(p.toRead.map(\.lastPathComponent).sorted() == ["exact.md", "new.md"])
    }

    @Test func parsesBlocksAndIgnoresSummary() throws {
        let srcs = TranscriptSource.parse(text: Self.transcript(summary: true), fileName: "2026-11-05 10-02.md")
        #expect(srcs.count == 2)
        #expect(srcs[0].id == "2026-11-05 10-02.md#0")
        #expect(srcs[0].kind == .transcript(fileName: "2026-11-05 10-02.md"))
        #expect(srcs[0].speaker == .them)
        #expect(srcs[0].time == Self.local("2026-11-05 10:14"))
        #expect(srcs[0].text == "Can you send me the deck by Friday?")
        #expect(srcs[1].id == "2026-11-05 10-02.md#1")
        #expect(srcs[1].speaker == .you)
        #expect(srcs[1].time == Self.local("2026-11-05 10:20"))
        #expect(srcs[1].text == "Sure, so we drop the legacy export, that's decided.")
    }

    @Test func blockEndsAtNextHeading() {
        let t = Self.transcript() + "\n## Notes\nignored text\n"
        let srcs = TranscriptSource.parse(text: t, fileName: "x.md")
        #expect(srcs.count == 2)
        #expect(!srcs[1].text.contains("ignored"))
    }
}
