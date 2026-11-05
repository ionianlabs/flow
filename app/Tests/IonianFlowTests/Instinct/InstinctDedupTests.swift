import Foundation
import Testing
@testable import IonianFlow

@Suite struct InstinctDedupTests {
    static func item(_ text: String, project: String = "alpha") -> InstinctItem {
        InstinctItem(category: .todo, text: text, owner: nil, due: nil, quote: text, sourceID: "s", project: project,
                     confidence: 0.8, conflicts: nil)
    }
    static func line(_ text: String, _ origin: BrainLine.Origin = .projectField) -> BrainLine {
        BrainLine(text: text, project: "alpha", origin: origin)
    }

    // F1.22: the overlap step alone decides, the model is not asked.
    @Test func overlapDuplicateSkipsModel() async {
        let model = FakeInstinctModel()
        let r = await InstinctDedup(model: model).check(Self.item("Send the deck"), against: [Self.line("Send the deck to the board")], earlier: [])
        #expect(r == .duplicate)
        #expect(model.judgeCalls.isEmpty)
    }

    // F1.23: the overlap misses, the model answers same.
    @Test func modelSameIsDuplicate() async {
        let model = FakeInstinctModel(); model.verdict = .same
        let log = BrainLine(text: "Decision: Legacy export is dropped in Q1", project: "alpha", origin: .log)
        let r = await InstinctDedup(model: model).check(Self.item("Drop the legacy export"), against: [log], earlier: [])
        #expect(r == .duplicate)
        #expect(model.judgeCalls.first?.lines == ["Decision: Legacy export is dropped in Q1"])
    }

    // F1.24: a rejected item from an archived Instinct file comes up again.
    @Test func rejectedItemIsDuplicate() async {
        let model = FakeInstinctModel(); model.verdict = .same
        let r = await InstinctDedup(model: model).check(Self.item("Investigate caching layer"),
                against: [Self.line("Look into caching", .instinct)], earlier: [])
        #expect(r == .duplicate)
    }

    // F1.25: the same request three times in one sweep keeps one.
    @Test func sameRequestThriceKeepsOne() async {
        let model = FakeInstinctModel()
        let dedup = InstinctDedup(model: model)
        var kept: [InstinctItem] = []
        for _ in 0..<3 {
            if case .keep(let i) = await dedup.check(Self.item("Send the deck"), against: [], earlier: kept) { kept.append(i) }
        }
        #expect(kept.count == 1)
    }

    // F1.26: conflicts keeps the item with the conflicting line set.
    @Test func conflictsKeepsItemWithLine() async {
        let model = FakeInstinctModel(); model.verdict = .conflicts("launch in April")
        let r = await InstinctDedup(model: model).check(Self.item("Launch moved to June"),
                against: [Self.line("launch in April")], earlier: [])
        var expected = Self.item("Launch moved to June"); expected.conflicts = "launch in April"
        #expect(r == .keep(expected))
    }

    @Test func newIsKept() async {
        let model = FakeInstinctModel(); model.verdict = .new
        let item = Self.item("Renew the vendor contract")
        let r = await InstinctDedup(model: model).check(item, against: [Self.line("Renew the vendor contract soon please")], earlier: [])
        #expect(r == .keep(item))
        #expect(model.judgeCalls.count == 1)
    }

    // No line with any overlap: the model is not asked, the item is kept.
    @Test func noOverlapSkipsModel() async {
        let model = FakeInstinctModel(); model.verdict = .same
        let item = Self.item("Renew the vendor contract")
        let r = await InstinctDedup(model: model).check(item, against: [Self.line("Weekly standup moved")], earlier: [])
        #expect(r == .keep(item))
        #expect(model.judgeCalls.isEmpty)
    }

    // The model sees at most the top 20 lines.
    @Test func modelSeesTopTwentyLines() async {
        let model = FakeInstinctModel()
        let lines = (0..<30).map { Self.line("deck number\($0) review extra words here") }
        _ = await InstinctDedup(model: model).check(Self.item("deck review"), against: lines, earlier: [])
        #expect(model.judgeCalls.first?.lines.count == 20)
    }

    // A judge error keeps the item.
    @Test func judgeErrorKeepsItem() async {
        let model = FakeInstinctModel(); model.judgeThrows = true
        let item = Self.item("Renew the vendor contract")
        let r = await InstinctDedup(model: model).check(item, against: [Self.line("Renew the vendor contract soon please")], earlier: [])
        #expect(r == .keep(item))
    }
}
