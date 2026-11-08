import Foundation
import Testing
@testable import IonianFlow

// Unit tests for CaptureBuffer: spec F1.1 (buffer side), F1.5, F1.6, F1.7, F1.8, F1.34 (removal). Temporary folder, injected clock.
extension IonianFlowTests {
@Suite struct CaptureBufferTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func makeFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aware-buffer-\(UUID().uuidString)")
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // F1.1 (buffer side)
    @Test func appendWritesOneLine() throws {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let buffer = CaptureBuffer(folder: folder, now: { clock.now })
        let entry = buffer.append(text: "Remind me to renew the vendor contract by Friday", app: "Notes", bundle: "com.apple.Notes")
        let raw = try String(contentsOf: folder.appendingPathComponent("buffer.jsonl"), encoding: .utf8)
        let lines = raw.split(separator: "\n")
        #expect(lines.count == 1)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        #expect(obj["text"] == "Remind me to renew the vendor contract by Friday")
        #expect(obj["app"] == "Notes")
        #expect(obj["bundle"] == "com.apple.Notes")
        #expect(obj["id"] == entry?.id && UUID(uuidString: obj["id"] ?? "") != nil)
        #expect(obj["time"] == ISO8601DateFormatter().string(from: clock.now))
        #expect(buffer.read().count == 1 && buffer.read()[0].text == "Remind me to renew the vendor contract by Friday")
    }

    // F1.5 (buffer side)
    @Test func fileModeIs0600AlsoAfterRewrite() {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let buffer = CaptureBuffer(folder: folder, now: { clock.now })
        let file = folder.appendingPathComponent("buffer.jsonl")
        buffer.append(text: "one two three", app: "Notes", bundle: "b")
        #expect(mode(file) == 0o600)
        clock.now.addTimeInterval(25 * 3600)
        buffer.append(text: "four five six", app: "Notes", bundle: "b") // rewrites without the old line
        #expect(mode(file) == 0o600)
        let id = buffer.read()[0].id
        buffer.remove(ids: [id])
        #expect(mode(file) == 0o600)
    }

    // F1.6
    @Test func badLineSkippedAndLoggedOnce() throws {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        var logged: [String] = []
        let buffer = CaptureBuffer(folder: folder, now: { clock.now }, log: { logged.append($0) })
        buffer.append(text: "first good line", app: "A", bundle: "a")
        let file = folder.appendingPathComponent("buffer.jsonl")
        var raw = try String(contentsOf: file, encoding: .utf8)
        raw += "this is not json\n"
        try raw.write(to: file, atomically: true, encoding: .utf8)
        buffer.append(text: "second good line", app: "A", bundle: "a")
        _ = buffer.read(); _ = buffer.read()
        #expect(buffer.read().map(\.text) == ["first good line", "second good line"])
        #expect(logged.count == 1)
    }

    // F1.7
    @Test func linesOlderThan24HoursAreDroppedOnReadAndAppend() throws {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let buffer = CaptureBuffer(folder: folder, now: { clock.now })
        buffer.append(text: "old one", app: "A", bundle: "a")
        clock.now.addTimeInterval(23 * 3600)
        buffer.append(text: "middle one", app: "A", bundle: "a")
        clock.now.addTimeInterval(2 * 3600) // old is 25 h, middle 2 h
        #expect(buffer.read().map(\.text) == ["middle one"])
        let raw = try String(contentsOf: folder.appendingPathComponent("buffer.jsonl"), encoding: .utf8)
        #expect(raw.split(separator: "\n").count == 1) // file rewritten, not only filtered
        clock.now.addTimeInterval(23 * 3600) // middle is 25 h
        buffer.append(text: "new one", app: "A", bundle: "a")
        let raw2 = try String(contentsOf: folder.appendingPathComponent("buffer.jsonl"), encoding: .utf8)
        #expect(raw2.split(separator: "\n").count == 1 && raw2.contains("new one") && !raw2.contains("middle one"))
    }

    // F1.8
    @Test func oldestLinesDroppedAtOneMegabyte() throws {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let buffer = CaptureBuffer(folder: folder, now: { clock.now })
        let big = String(repeating: "x", count: 100_000)
        for i in 0..<10 { buffer.append(text: "\(i) " + big, app: "A", bundle: "a") }
        #expect(buffer.read().count == 10)
        buffer.append(text: "10 " + big, app: "A", bundle: "a")
        let texts = buffer.read().map { String($0.text.prefix(2)) }
        #expect(texts.first == "1 " && texts.last == "10" && texts.count == 10)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("buffer.jsonl").path)[.size] as? Int)
        #expect(size <= 1_048_576)
    }

    // F1.34
    @Test func removeDeletesExactlyTheGivenIds() {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let buffer = CaptureBuffer(folder: folder, now: { clock.now })
        let a = buffer.append(text: "alpha alpha alpha", app: "A", bundle: "a")
        buffer.append(text: "beta beta beta", app: "A", bundle: "a")
        let c = buffer.append(text: "gamma gamma gamma", app: "A", bundle: "a")
        buffer.remove(ids: [a!.id, c!.id, "no-such-id"])
        #expect(buffer.read().map(\.text) == ["beta beta beta"])
    }
}
}
