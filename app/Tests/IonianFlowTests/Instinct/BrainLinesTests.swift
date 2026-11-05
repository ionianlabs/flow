import Foundation
import Testing
@testable import IonianFlow

/// Fixture brain in a temporary folder; invented names only.
struct FixtureBrain {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString)")
        for d in ["inbox", "projects", "logs", "_archive/inbox"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try write("AGENTS.md", "# Agents\n")
    }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    static let alpha = """
    ---
    description: "Alpha rollout"
    focus: Ship the board deck
    ---

    # Alpha

    ## Now
    - Launch in April
    Waiting on Dana

    ## Open
    - [ ] Send the deck to the board (owner: Sam, due: 2026-11-10)
    - [x] Book the room

    ## People
    - Sam
    """
}

extension IonianFlowTests {
@Suite struct BrainLinesTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!

    @Test func isBrainNeedsAgentsInboxProjects() throws {
        let b = try FixtureBrain()
        #expect(BrainLines.isBrain(b.root))
        try FileManager.default.removeItem(at: b.root.appendingPathComponent("inbox"))
        #expect(!BrainLines.isBrain(b.root))
        #expect(!BrainLines.isBrain(b.root.appendingPathComponent("missing")))
    }

    @Test func readsProjects() throws {
        let b = try FixtureBrain()
        try b.write("projects/alpha.md", FixtureBrain.alpha)
        try b.write("projects/.hidden/beta.md", FixtureBrain.alpha)
        let ps = BrainLines.projects(in: b.root)
        #expect(ps.count == 1)
        let p = try #require(ps.first)
        #expect(p.slug == "alpha")
        #expect(p.description == "Alpha rollout")
        #expect(p.focus == "Ship the board deck")
        #expect(p.now == ["Launch in April", "Waiting on Dana"])
        #expect(p.open == ["Send the deck to the board (owner: Sam, due: 2026-11-10)", "Book the room"])
    }

    @Test func linesFromProjectFieldsAndLogs() throws {
        let b = try FixtureBrain()
        try b.write("projects/alpha.md", FixtureBrain.alpha)
        try b.write("logs/alpha.md", """
        # Log

        ## 2026-10-28
        - Decision: Legacy export is dropped in Q1
        - Done: Sent the draft

        ## 2026-10-01
        - Decision: Too old
        """)
        let lines = BrainLines.lines(in: b.root, now: now)
        #expect(lines.contains { $0.text == "Alpha rollout" && $0.project == "alpha" && $0.origin == .projectField })
        #expect(lines.contains { $0.text == "Ship the board deck" && $0.origin == .projectField })
        #expect(lines.contains { $0.text == "Launch in April" && $0.origin == .projectField })
        #expect(lines.contains { $0.text == "Decision: Legacy export is dropped in Q1" && $0.project == "alpha" && $0.origin == .log })
        #expect(!lines.contains { $0.text.contains("Too old") })
    }

    @Test func rejectedItemInArchiveStaysForThirtyDays() throws {
        let b = try FixtureBrain()
        try b.write("_archive/inbox/2026-10-20-instinct.md", """
        ---
        type: capture
        ---
        # Instinct 2026-10-20

        ## 12:00
        - [-] todo: Look into caching (owner: Sam, due: 2026-10-25) → alpha > "look into caching" (Notes 2026-10-20 10:41, 0.77)
        - [ ] fact: Launch moved to June → none > "the launch moved" (x, 0.7) conflicts: "launch in April"
        """)
        try b.write("_archive/inbox/2026-09-01-instinct.md", "- [x] decision: Old news → alpha > \"q\" (x)\n")
        try b.write("inbox/2026-11-05-instinct.md", "- [=] decision: Drop the export → beta > \"q\" (x)\n")
        let lines = BrainLines.lines(in: b.root, now: now)
        #expect(lines.contains { $0.text == "Look into caching" && $0.project == "alpha" && $0.origin == .instinct })
        #expect(lines.contains { $0.text == "Launch moved to June" && $0.project == nil })
        #expect(lines.contains { $0.text == "Drop the export" && $0.project == "beta" })
        #expect(!lines.contains { $0.text == "Old news" })
    }
}
}
