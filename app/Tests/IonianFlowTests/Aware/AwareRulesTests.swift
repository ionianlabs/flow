import Foundation
import Testing
@testable import IonianFlow

// Unit tests for AwareRules: F1.20, F1.21, F1.22 (overlap step), F1.27 (cut helper).
extension IonianFlowTests {
@Suite struct AwareRulesTests {
    private struct Cand { var name: String; var conf: Double }

    // F1.20, F1.21
    @Test func knowledgeWithoutProjectIsDropped() {
        #expect(AwareRules.gate(kind: "decision", project: "none", confidence: 0.95) == .noProject)
        #expect(AwareRules.gate(kind: "fact", project: "none", confidence: 0.95) == .noProject)
        #expect(AwareRules.gate(kind: "todo", project: "none", confidence: 0.6) == nil)
        #expect(AwareRules.gate(kind: "decision", project: "alpha", confidence: 0.95) == nil)
    }

    @Test func confidenceFloors() {
        #expect(AwareRules.gate(kind: "todo", project: "alpha", confidence: 0.49) == .lowConfidence)
        #expect(AwareRules.gate(kind: "todo", project: "alpha", confidence: 0.5) == nil)
        #expect(AwareRules.gate(kind: "decision", project: "alpha", confidence: 0.69) == .lowConfidence)
        #expect(AwareRules.gate(kind: "decision", project: "alpha", confidence: 0.7) == nil)
        #expect(AwareRules.gate(kind: "fact", project: "alpha", confidence: 0.69) == .lowConfidence)
        #expect(AwareRules.gate(kind: "fact", project: "alpha", confidence: 0.7) == nil)
    }

    // F1.22
    @Test func contentWordsLowercaseSplitAndDropStopWords() {
        #expect(AwareRules.contentWords("Send the deck to the Board!") == ["send", "deck", "board"])
        #expect(AwareRules.contentWords("Q1-budget: v2 is final") == ["q1", "budget", "v2", "final"])
        #expect(AwareRules.contentWords("Wir senden die Folien an den Vorstand") == ["senden", "folien", "vorstand"])
        // no stemming
        #expect(AwareRules.contentWords("dropped drop") == ["dropped", "drop"])
        #expect(AwareRules.contentWords("the and of").isEmpty)
    }

    @Test func stopWordListIsAFixedEnglishAndGermanList() {
        let sw = AwareRules.stopWords
        #expect(sw.count >= 150 && sw.count <= 250)
        for w in ["the", "and", "to", "of", "is", "der", "die", "und", "ist", "zu"] { #expect(sw.contains(w), "\(w)") }
        for w in ["send", "deck", "drop", "export", "launch", "contract", "senden", "folien"] { #expect(!sw.contains(w), "\(w)") }
        #expect(sw.allSatisfy { $0 == $0.lowercased() })
    }

    @Test func jaccardIsIntersectionOverUnion() {
        #expect(AwareRules.jaccard(["a", "b"], ["a", "b", "c"]) == 2.0 / 3.0)
        #expect(AwareRules.jaccard(["a"], ["b"]) == 0)
        #expect(AwareRules.jaccard(["a", "b"], ["a", "b"]) == 1)
        #expect(AwareRules.jaccard([], []) == 0)
    }

    @Test func overlapDuplicateAtThreshold() {
        #expect(AwareRules.overlapThreshold == 0.6)
        // F1.22 example: {send, deck} against {send, deck, board} is 2/3.
        let r = AwareRules.rankByOverlap(item: "Send the deck", lines: ["- [ ] Renew the vendor contract", "- [ ] Send the deck to the board"])
        #expect(r.duplicate)
        #expect(r.top.first?.line == "- [ ] Send the deck to the board")
        // Exactly 0.6 counts: 3 shared of 5 distinct.
        let edge = AwareRules.rankByOverlap(item: "alpha beta gamma", lines: ["alpha beta gamma delta epsilon"])
        #expect(edge.duplicate && edge.top[0].score == 0.6)
        // Just under: 3 of 6.
        let under = AwareRules.rankByOverlap(item: "alpha beta gamma", lines: ["alpha beta gamma delta epsilon zeta"])
        #expect(!under.duplicate)
    }

    @Test func rankByOverlapKeepsTheTwentyBestInOrder() {
        let lines = (0..<30).map { "alpha beta w\($0)" } + ["unrelated words entirely", "alpha beta gamma"]
        let r = AwareRules.rankByOverlap(item: "alpha beta gamma", lines: lines)
        #expect(r.top.count == 20)
        #expect(r.top[0].line == "alpha beta gamma")
        #expect(!r.top.contains { $0.line == "unrelated words entirely" })
        #expect(zip(r.top, r.top.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(r.duplicate)
        let none = AwareRules.rankByOverlap(item: "quarterly forecast review", lines: ["unrelated words entirely"])
        #expect(none.top.isEmpty && !none.duplicate)
    }

    // F1.27
    @Test func capConstants() {
        #expect(AwareRules.perSweepCap == 10)
        #expect(AwareRules.perDayCap == 25)
    }

    @Test func fourteenItemsKeepTheTenMostConfident() {
        let confs: [Double] = [0.9, 0.55, 0.8, 0.75, 0.6, 0.95, 0.7, 0.85, 0.5, 0.65, 0.9, 0.72, 0.58, 0.77]
        let items: [Cand] = confs.enumerated().map { Cand(name: "i\($0.offset)", conf: $0.element) }
        let r = AwareRules.keepHighestConfidence(items, limit: AwareRules.perSweepCap, confidence: { $0.conf })
        #expect(r.kept.count == 10 && r.cut == 4)
        // The four lowest are 0.5 (i8), 0.55 (i1), 0.58 (i12), 0.6 (i4).
        #expect(Set(r.kept.map { $0.name }) == ["i0", "i2", "i3", "i5", "i6", "i7", "i9", "i10", "i11", "i13"])
        let few = AwareRules.keepHighestConfidence(Array(items.prefix(3)), limit: 10, confidence: { $0.conf })
        #expect(few.kept.count == 3 && few.cut == 0)
        // ties keep the earlier item
        let ties = AwareRules.keepHighestConfidence(["a", "b", "c"], limit: 2, confidence: { _ in 0.8 })
        #expect(ties.kept == ["a", "b"] && ties.cut == 1)
    }

    // Due-date year rollover: a date before the source's day that was said as month and day only moves one year ahead.
    @Test func dueBeforeTheSourceWithAMonthAndDayMovesAYearAhead() {
        let src = awareTestDate(2026, 11, 5)
        func roll(_ due: String?, _ quote: String) -> String? { AwareRules.rolledDue(due, quote: quote, sourceTime: src) }
        #expect(roll("2026-03-03", "Please send it by the third of March") == "2027-03-03")
        #expect(roll("2026-01-15", "deadline is Jan 15") == "2027-01-15")
        #expect(roll("2026-03-03", "Please send it by 3 March 2026") == "2026-03-03")   // the year was said
        #expect(roll("2026-11-04", "I needed it by yesterday") == "2026-11-04")          // no month said
        #expect(roll("2026-11-05", "by the fifth of November") == "2026-11-05")          // today is not before today
        #expect(roll("2026-12-01", "by the first of December") == "2026-12-01")
        #expect(roll(nil, "by the first of March") == nil)
        #expect(roll("soon", "by the first of March") == "soon")
        #expect(roll("2026-02-28", "by the 28th of February") == "2027-02-28")
    }

    // Evidence in the quote: a fact needs something concrete, a decision a settling phrase; a to-do needs nothing more.
    @Test func factsNeedAConcreteDetailInTheQuote() {
        func ok(_ q: String) -> Bool { AwareRules.hasEvidence(kind: "fact", quote: q) }
        #expect(ok("The nightly sync now handles about forty thousand records."))
        #expect(ok("The audit is on the third of March."))
        #expect(ok("The beta opens on 18 January."))
        #expect(ok("The reporting service is now called Orchid, the old name is retired."))
        #expect(ok("Der Dienst heißt jetzt umbenannt Orchid."))
        #expect(!ok("Yeah, the diagram on the wiki is outdated, but the general idea is still right."))
        #expect(!ok("The thing about that module is that it grew organically, so nobody remembers why half of it exists."))
        #expect(!ok("what happened was, the request came in, it got a bit stuck, and then it just went through on its own."))
    }

    @Test func decisionsNeedASettlingPhrase() {
        func ok(_ q: String) -> Bool { AwareRules.hasEvidence(kind: "decision", quote: q) }
        #expect(ok("Okay, so we go with the weekly release train, that's settled."))
        #expect(ok("We are not renewing the licence, that is the final call."))
        #expect(ok("We will use Postgres for the ledger."))
        #expect(ok("We decided to use Postgres for the ledger."))
        #expect(ok("Wir haben das so entschieden."))
        #expect(!ok("I would not want to commit to anything right now."))
        #expect(!ok("Sounds good, let's do that."))
    }

    @Test func todosNeedNoMoreEvidence() {
        #expect(AwareRules.hasEvidence(kind: "todo", quote: "anything at all"))
    }

    // Weekday resolution in code: the next such day strictly after the source's day, whatever the model said.
    @Test func weekdayInTheQuoteSetsTheNextOccurrence() {
        func due(_ quote: String, _ y: Int, _ m: Int, _ d: Int, model: String? = nil) -> String? {
            AwareRules.weekdayDue(model, quote: quote, sourceTime: awareTestDate(y, m, d))
        }
        #expect(due("Remember to bring the ladder on Thursday.", 2026, 11, 3, model: "2026-11-04") == "2026-11-05")   // held-out case, Tuesday
        #expect(due("Could you book the room for next Monday, ten o'clock?", 2026, 11, 5) == "2026-11-09")           // Thursday
        #expect(due("Please send it by Thursday", 2026, 11, 5) == "2026-11-12")                                        // same weekday: a week later
        #expect(due("Bitte bis nächsten Freitag", 2026, 11, 5) == "2026-11-06")
        #expect(due("Das schicke ich am Montag", 2026, 11, 5) == "2026-11-09")
        #expect(due("Send it tomorrow", 2026, 12, 31) == "2027-01-01")
        #expect(due("Schick es morgen", 2026, 11, 5, model: "2026-01-01") == "2026-11-06")
        #expect(due("Send it by 12 November on Thursday", 2026, 11, 5, model: "2026-11-12") == "2026-11-12")   // explicit date wins
        #expect(due("Send it soon", 2026, 11, 5, model: "2026-11-20") == "2026-11-20")
        #expect(due("Send it soon", 2026, 11, 5) == nil)
    }
}
}
