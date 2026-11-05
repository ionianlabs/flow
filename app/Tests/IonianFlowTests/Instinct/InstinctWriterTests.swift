import Foundation
import Testing
@testable import IonianFlow

@Suite struct InstinctWriterTests {
    static func local(_ s: String) -> Date { TranscriptSourceTests.local(s) }

    static func brain() throws -> URL { try TranscriptSourceTests.tmp() }

    static func meetingSource(_ block: Int, _ speaker: InstinctSpeaker, _ time: String) -> InstinctSource {
        InstinctSource(id: "2026-11-05 10-02.md#\(block)", kind: .transcript(fileName: "2026-11-05 10-02.md"),
                       time: local("2026-11-05 \(time)"), speaker: speaker, text: "x")
    }
    static let dictation = InstinctSource(id: "d1", kind: .dictation(app: "Notes", bundle: "com.apple.Notes"),
                                          time: local("2026-11-05 10:41"), speaker: nil, text: "x")

    static func item(_ cat: InstinctCategory, _ text: String, owner: String? = nil, due: String? = nil,
                     quote: String, source: String, project: String = "alpha", conf: Double,
                     conflicts: String? = nil) -> InstinctItem {
        InstinctItem(category: cat, text: text, owner: owner, due: due, quote: quote, sourceID: source,
                     project: project, confidence: conf, conflicts: conflicts)
    }

    static func writer(_ brain: URL, transcripts: URL? = nil) -> InstinctWriter {
        InstinctWriter(brainRoot: brain, transcriptsFolder: transcripts ?? brain.appendingPathComponent("transcripts"))
    }

    static let counts = InstinctDropCounts(byRules: 9, noProject: 1, lowConfidence: 2, duplicate: 3,
                                           quoteNotFound: 0, unreadable: 0, belowCut: 0)

    static func firstSweepItems() -> [InstinctWriter.Entry] {
        [.init(item: item(.todo, "Send the deck", due: "2026-11-06", quote: "Can you send me the deck by Friday?", source: "m0", conf: 0.82),
               source: meetingSource(0, .them, "10:14")),
         .init(item: item(.decision, "Drop the legacy export", quote: "so we drop the legacy export, that's decided", source: "m1", conf: 0.88),
               source: meetingSource(1, .you, "10:20")),
         .init(item: item(.fact, "Launch moved to June", quote: "the launch moved to June", source: "m2", conf: 0.74, conflicts: "launch in April"),
               source: meetingSource(2, .them, "10:31")),
         .init(item: item(.todo, "Renew the vendor contract", owner: "Sam", due: "2026-11-06", quote: "Remind me to renew the vendor contract by Friday",
                          source: "d1", project: "none", conf: 0.77),
               source: dictation)]
    }

    // F1.29: first sweep creates the file in the exact format.
    @Test func createsDayFile() throws {
        let brain = try Self.brain()
        let w = Self.writer(brain)
        #expect(w.itemsToday(on: Self.local("2026-11-05 12:00")) == 0)
        let url = try #require(try w.write(at: Self.local("2026-11-05 12:00"), kind: .scheduled,
                                           entries: Self.firstSweepItems(), meetings: 1, dictations: 12, dropped: Self.counts))
        #expect(url.path.hasSuffix("inbox/2026-11-05-instinct.md"))
        let expected = """
        ---
        type: capture
        description: "Instinct: 4 items from 1 meeting and 12 dictations"
        tags: [automation]
        org: unknown
        source: flow
        updated: 2026-11-05
        ---

        # Instinct 2026-11-05

        Mark each line: [x] accept, [~] edited, [-] reject, [=] duplicate.

        ## 12:00
        - [ ] todo: Send the deck (due: 2026-11-06) → alpha > "Can you send me the deck by Friday?" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:14, Them, 0.82)
        - [ ] decision: Drop the legacy export → alpha > "so we drop the legacy export, that's decided" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:20, You, 0.88)
        - [ ] fact: Launch moved to June → alpha > "the launch moved to June" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:31, Them, 0.74) conflicts: "launch in April"
        - [ ] todo: Renew the vendor contract (owner: Sam, due: 2026-11-06) → none > "Remind me to renew the vendor contract by Friday" (Notes 2026-11-05 10:41, 0.77)

        Swept 1 meeting, 12 dictations. Dropped: 9 by rules, 1 no project, 2 low confidence, 3 duplicate, 0 quote not found, 0 unreadable, 0 below the cut.

        """
        #expect(try String(contentsOf: url, encoding: .utf8) == expected)
        #expect(w.itemsToday(on: Self.local("2026-11-05 13:00")) == 4)
        #expect(w.itemsToday(on: Self.local("2026-11-06 09:00")) == 0)
    }

    // F1.29: a later sweep appends a section; existing lines stay, the user's marks too.
    @Test func appendsSectionAndRecomputesDescription() throws {
        let brain = try Self.brain()
        let w = Self.writer(brain)
        let url = try #require(try w.write(at: Self.local("2026-11-05 12:00"), kind: .scheduled,
                                           entries: Self.firstSweepItems(), meetings: 1, dictations: 12, dropped: Self.counts))
        // the user accepts the first line
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "- [ ] todo: Send the deck", with: "- [x] todo: Send the deck")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let before = text.components(separatedBy: "\n")

        let more = [InstinctWriter.Entry(item: Self.item(.todo, "Call Dana", quote: "call Dana tomorrow", source: "d2", conf: 0.8),
                                         source: Self.dictation)]
        let second = try #require(try w.write(at: Self.local("2026-11-05 15:00"), kind: .scheduled, entries: more,
                                              meetings: 0, dictations: 5, dropped: InstinctDropCounts()))
        #expect(second == url)
        let after = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let keep = { (ls: [String]) in ls.filter { !$0.hasPrefix("description:") && !$0.hasPrefix("updated:") } }
        #expect(Array(keep(after).prefix(keep(before).count - 1)) == Array(keep(before).dropLast()))
        #expect(after.contains(#"description: "Instinct: 5 items from 1 meeting and 17 dictations""#))
        #expect(after.contains("## 15:00"))
        #expect(after.contains("- [x] todo: Send the deck (due: 2026-11-06) → alpha > \"Can you send me the deck by Friday?\" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:14, Them, 0.82)"))
        #expect(after.last(where: { $0.hasPrefix("## ") }) == "## 15:00")
        #expect(w.itemsToday(on: Self.local("2026-11-05 16:00")) == 5)
    }

    @Test func updatedIsRecomputedOnAppend() throws {
        let brain = try Self.brain()
        let w = Self.writer(brain)
        let url = try #require(try w.write(at: Self.local("2026-11-05 23:50"), kind: .scheduled,
                                           entries: Self.firstSweepItems(), meetings: 0, dictations: 1, dropped: InstinctDropCounts()))
        _ = try w.write(at: Self.local("2026-11-05 23:59"), kind: .scheduled,
                        entries: Array(Self.firstSweepItems().prefix(1)), meetings: 0, dictations: 1, dropped: InstinctDropCounts())
        #expect(try String(contentsOf: url, encoding: .utf8).contains("updated: 2026-11-05"))
    }

    // Meeting sweep heading and singular/plural.
    @Test func meetingSectionHeading() throws {
        let brain = try Self.brain()
        let w = Self.writer(brain)
        let url = try #require(try w.write(at: Self.local("2026-11-05 10:46"), kind: .meeting,
                                           entries: Array(Self.firstSweepItems().prefix(1)), meetings: 1, dictations: 0, dropped: InstinctDropCounts()))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n## 10:46 meeting\n"))
        #expect(text.contains(#"description: "Instinct: 1 item from 1 meeting and 0 dictations""#))
        #expect(text.contains("Swept 1 meeting, 0 dictations. Dropped: 0 by rules,"))
    }

    // F1.30: no items, nothing written.
    @Test func noItemsWritesNothing() throws {
        let brain = try Self.brain()
        let w = Self.writer(brain)
        let r = try w.write(at: Self.local("2026-11-05 12:00"), kind: .scheduled, entries: [], meetings: 0, dictations: 3, dropped: Self.counts)
        #expect(r == nil)
        #expect(!FileManager.default.fileExists(atPath: brain.appendingPathComponent("inbox").path))
    }

    // Source form when the transcripts folder is outside the brain: file name plus time.
    @Test func transcriptOutsideBrainUsesFileName() throws {
        let brain = try Self.brain()
        let outside = try TranscriptSourceTests.tmp()
        let w = Self.writer(brain, transcripts: outside)
        let url = try #require(try w.write(at: Self.local("2026-11-05 10:46"), kind: .meeting,
                                           entries: Array(Self.firstSweepItems().prefix(1)), meetings: 1, dictations: 0, dropped: InstinctDropCounts()))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("(2026-11-05 10-02.md 10:14, Them, 0.82)"))
        #expect(!text.contains("](/"))
    }
}
