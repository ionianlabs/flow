import Foundation
import Testing
@testable import IonianFlow

extension IonianFlowTests {
@Suite struct InstinctPrecisionTests {
    func line(_ mark: String, _ cat: String, _ n: Int) -> String {
        "- [\(mark)] \(cat): Item \(n) → alpha > \"quote\" (Notes 2026-10-20 10:41, 0.8)"
    }

    /// F2.1: 10 decision lines (7 x, 1 ~, 1 -, 1 =) over three files.
    func fixture() throws -> FixtureBrain {
        let b = try FixtureBrain()
        let d = (0..<7).map { line("x", "decision", $0) } + [line("~", "decision", 7)]
        try b.write("_archive/inbox/2026-10-20-instinct.md", "# Instinct\n\n## 12:00\n" + d.joined(separator: "\n") + "\n")
        try b.write("_archive/inbox/2026-10-21-instinct.md", [line("-", "decision", 8), line("x", "todo", 9), line("-", "todo", 10), line("x", "todo", 11)].joined(separator: "\n") + "\n")
        try b.write("_archive/inbox/2026-10-22-instinct.md", [line("=", "decision", 12), line(" ", "fact", 13), line(" ", "todo", 14)].joined(separator: "\n") + "\n")
        try b.write("_archive/inbox/notes.md", line("x", "fact", 99))
        return b
    }

    @Test func f21_linesPerCategory() throws {
        let b = try fixture()
        let out = InstinctPrecision.report(archive: b.root.appendingPathComponent("_archive/inbox"))
        #expect(out == "todo 2/3 67% duplicates 0\ndecision 8/10 80% duplicates 1\nunreviewed 2")
    }

    @Test func f21_categoryWithoutMarkedLinesNotPrinted() throws {
        let b = try FixtureBrain()
        try b.write("_archive/inbox/2026-10-20-instinct.md", line("x", "fact", 1) + "\n" + line(" ", "todo", 2) + "\n")
        let out = InstinctPrecision.report(archive: b.root.appendingPathComponent("_archive/inbox"))
        #expect(out == "fact 1/1 100% duplicates 0\nunreviewed 1")
    }

    @Test func f22_unreviewedLineAlwaysLast() throws {
        let b = try FixtureBrain()
        let out = InstinctPrecision.report(archive: b.root.appendingPathComponent("_archive/inbox"))
        #expect(out == "unreviewed 0")
    }

    @Test func f23_brainOptionAndNoBrain() throws {
        let b = try fixture()
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(InstinctPrecision.archive(args: ["--brain", b.root.path], vault: nil) == b.root.appendingPathComponent("_archive/inbox"))
        #expect(InstinctPrecision.archive(args: [], vault: b.root) == b.root.appendingPathComponent("_archive/inbox"))
        #expect(InstinctPrecision.archive(args: ["--brain", none.path], vault: b.root) == nil)
        #expect(InstinctPrecision.archive(args: [], vault: nil) == nil)
    }
}
}
