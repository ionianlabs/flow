import Foundation
import Testing
@testable import IonianFlow

// Unit tests for InstinctRules: F1.2, F1.3, F1.4, F1.15, F1.20, F1.21, F1.22 (overlap step), F1.27 (cut helper).
extension IonianFlowTests {
@Suite struct InstinctRulesTests {
    private struct Cand { var name: String; var conf: Double }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // F1.2
    @Test func defaultExcludedAppsAreTheFivePasswordManagers() {
        #expect(Set(InstinctRules.defaultExcludedApps) == ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"])
    }

    @Test func excludedBundleStoresNothing() {
        let ex = InstinctRules.defaultExcludedApps
        #expect(!InstinctRules.shouldCapture(bundle: "com.bitwarden.desktop", excluded: ex, secureInput: false, pausedUntil: nil, now: now))
        #expect(InstinctRules.shouldCapture(bundle: "com.apple.Notes", excluded: ex, secureInput: false, pausedUntil: nil, now: now))
        #expect(InstinctRules.shouldCapture(bundle: "com.bitwarden.desktop", excluded: [], secureInput: false, pausedUntil: nil, now: now))
    }

    // F1.3
    @Test func secureInputStoresNothing() {
        #expect(!InstinctRules.shouldCapture(bundle: "com.apple.Notes", excluded: [], secureInput: true, pausedUntil: nil, now: now))
    }

    // F1.4
    @Test func pausedStoresNothingUntilTheTimeIsReached() {
        let until = now.addingTimeInterval(3600)
        #expect(!InstinctRules.shouldCapture(bundle: "a", excluded: [], secureInput: false, pausedUntil: until, now: now))
        #expect(!InstinctRules.shouldCapture(bundle: "a", excluded: [], secureInput: false, pausedUntil: until, now: until.addingTimeInterval(-1)))
        #expect(InstinctRules.shouldCapture(bundle: "a", excluded: [], secureInput: false, pausedUntil: until, now: until))
    }

    // F1.15
    @Test func prefilterConstantsMatchTheSpec() {
        #expect(Set(InstinctRules.codeApps) == ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed"])
        #expect(Set(InstinctRules.cues) == ["todo", "to do", "remind me", "note to self", "don't forget", "I need to", "we decided", "for the record", "erinner mich", "nicht vergessen", "wir haben entschieden"])
    }

    @Test func shortDictationsAreDropped() {
        #expect(InstinctRules.prefilter(text: "send it", bundle: "com.apple.Notes") == .tooShort)
        #expect(InstinctRules.prefilter(text: "  ok   thanks  ", bundle: "com.apple.Notes") == .tooShort)
        #expect(InstinctRules.prefilter(text: "send it now", bundle: "com.apple.Notes") == nil)
        // The word count comes before the app rule: a short Terminal line is "too short".
        #expect(InstinctRules.prefilter(text: "git status", bundle: "com.apple.Terminal") == .tooShort)
    }

    @Test func codeAppWithoutCueIsDropped() {
        #expect(InstinctRules.prefilter(text: "git rebase main and fix the merge conflicts", bundle: "com.apple.Terminal") == .codeAppNoCue)
        #expect(InstinctRules.prefilter(text: "git rebase main and fix the merge conflicts", bundle: "com.apple.Notes") == nil)
    }

    @Test func codeAppWithCueGoesToTheModel() {
        #expect(InstinctRules.prefilter(text: "note to self: rotate the staging key monthly", bundle: "com.apple.Terminal") == nil)
        #expect(InstinctRules.prefilter(text: "Wir haben entschieden den Export zu streichen", bundle: "com.microsoft.VSCode") == nil)
        #expect(InstinctRules.prefilter(text: "this is a TODO for the parser", bundle: "dev.zed.Zed") == nil)
        #expect(InstinctRules.prefilter(text: "that is on my to do list somewhere", bundle: "dev.zed.Zed") == nil)
        #expect(InstinctRules.prefilter(text: "I need to fix the lint step", bundle: "com.apple.dt.Xcode") == nil)
        #expect(InstinctRules.prefilter(text: "please don\u{2019}t forget the release notes", bundle: "com.apple.dt.Xcode") == nil)
        #expect(InstinctRules.prefilter(text: "please don't forget the release notes", bundle: "com.apple.dt.Xcode") == nil)
    }

    @Test func cuesMatchWholeWordsOnly() {
        // "todos" is not "todo"; "I need to" must not match inside "I need tomatoes".
        #expect(InstinctRules.prefilter(text: "rename all the todos in this file", bundle: "com.apple.Terminal") == .codeAppNoCue)
        #expect(InstinctRules.prefilter(text: "I need tomatoes and some basil", bundle: "com.apple.Terminal") == .codeAppNoCue)
        #expect(InstinctRules.prefilter(text: "the autodo helper does the sorting", bundle: "com.apple.Terminal") == .codeAppNoCue)
    }

    // F1.20, F1.21
    @Test func knowledgeWithoutProjectIsDropped() {
        #expect(InstinctRules.gate(kind: "decision", project: "none", confidence: 0.95) == .noProject)
        #expect(InstinctRules.gate(kind: "fact", project: "none", confidence: 0.95) == .noProject)
        #expect(InstinctRules.gate(kind: "todo", project: "none", confidence: 0.6) == nil)
        #expect(InstinctRules.gate(kind: "decision", project: "alpha", confidence: 0.95) == nil)
    }

    @Test func confidenceFloors() {
        #expect(InstinctRules.gate(kind: "todo", project: "alpha", confidence: 0.49) == .lowConfidence)
        #expect(InstinctRules.gate(kind: "todo", project: "alpha", confidence: 0.5) == nil)
        #expect(InstinctRules.gate(kind: "decision", project: "alpha", confidence: 0.69) == .lowConfidence)
        #expect(InstinctRules.gate(kind: "decision", project: "alpha", confidence: 0.7) == nil)
        #expect(InstinctRules.gate(kind: "fact", project: "alpha", confidence: 0.69) == .lowConfidence)
        #expect(InstinctRules.gate(kind: "fact", project: "alpha", confidence: 0.7) == nil)
    }

    // F1.22
    @Test func contentWordsLowercaseSplitAndDropStopWords() {
        #expect(InstinctRules.contentWords("Send the deck to the Board!") == ["send", "deck", "board"])
        #expect(InstinctRules.contentWords("Q1-budget: v2 is final") == ["q1", "budget", "v2", "final"])
        #expect(InstinctRules.contentWords("Wir senden die Folien an den Vorstand") == ["senden", "folien", "vorstand"])
        // no stemming
        #expect(InstinctRules.contentWords("dropped drop") == ["dropped", "drop"])
        #expect(InstinctRules.contentWords("the and of").isEmpty)
    }

    @Test func stopWordListIsAFixedEnglishAndGermanList() {
        let sw = InstinctRules.stopWords
        #expect(sw.count >= 150 && sw.count <= 250)
        for w in ["the", "and", "to", "of", "is", "der", "die", "und", "ist", "zu"] { #expect(sw.contains(w), "\(w)") }
        for w in ["send", "deck", "drop", "export", "launch", "contract", "senden", "folien"] { #expect(!sw.contains(w), "\(w)") }
        #expect(sw.allSatisfy { $0 == $0.lowercased() })
    }

    @Test func jaccardIsIntersectionOverUnion() {
        #expect(InstinctRules.jaccard(["a", "b"], ["a", "b", "c"]) == 2.0 / 3.0)
        #expect(InstinctRules.jaccard(["a"], ["b"]) == 0)
        #expect(InstinctRules.jaccard(["a", "b"], ["a", "b"]) == 1)
        #expect(InstinctRules.jaccard([], []) == 0)
    }

    @Test func overlapDuplicateAtThreshold() {
        #expect(InstinctRules.overlapThreshold == 0.6)
        // F1.22 example: {send, deck} against {send, deck, board} is 2/3.
        let r = InstinctRules.rankByOverlap(item: "Send the deck", lines: ["- [ ] Renew the vendor contract", "- [ ] Send the deck to the board"])
        #expect(r.duplicate)
        #expect(r.top.first?.line == "- [ ] Send the deck to the board")
        // Exactly 0.6 counts: 3 shared of 5 distinct.
        let edge = InstinctRules.rankByOverlap(item: "alpha beta gamma", lines: ["alpha beta gamma delta epsilon"])
        #expect(edge.duplicate && edge.top[0].score == 0.6)
        // Just under: 3 of 6.
        let under = InstinctRules.rankByOverlap(item: "alpha beta gamma", lines: ["alpha beta gamma delta epsilon zeta"])
        #expect(!under.duplicate)
    }

    @Test func rankByOverlapKeepsTheTwentyBestInOrder() {
        let lines = (0..<30).map { "alpha beta w\($0)" } + ["unrelated words entirely", "alpha beta gamma"]
        let r = InstinctRules.rankByOverlap(item: "alpha beta gamma", lines: lines)
        #expect(r.top.count == 20)
        #expect(r.top[0].line == "alpha beta gamma")
        #expect(!r.top.contains { $0.line == "unrelated words entirely" })
        #expect(zip(r.top, r.top.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(r.duplicate)
        let none = InstinctRules.rankByOverlap(item: "quarterly forecast review", lines: ["unrelated words entirely"])
        #expect(none.top.isEmpty && !none.duplicate)
    }

    // F1.27
    @Test func capConstants() {
        #expect(InstinctRules.perSweepCap == 10)
        #expect(InstinctRules.perDayCap == 25)
    }

    @Test func fourteenItemsKeepTheTenMostConfident() {
        let confs: [Double] = [0.9, 0.55, 0.8, 0.75, 0.6, 0.95, 0.7, 0.85, 0.5, 0.65, 0.9, 0.72, 0.58, 0.77]
        let items: [Cand] = confs.enumerated().map { Cand(name: "i\($0.offset)", conf: $0.element) }
        let r = InstinctRules.keepHighestConfidence(items, limit: InstinctRules.perSweepCap, confidence: { $0.conf })
        #expect(r.kept.count == 10 && r.cut == 4)
        // The four lowest are 0.5 (i8), 0.55 (i1), 0.58 (i12), 0.6 (i4).
        #expect(Set(r.kept.map { $0.name }) == ["i0", "i2", "i3", "i5", "i6", "i7", "i9", "i10", "i11", "i13"])
        let few = InstinctRules.keepHighestConfidence(Array(items.prefix(3)), limit: 10, confidence: { $0.conf })
        #expect(few.kept.count == 3 && few.cut == 0)
        // ties keep the earlier item
        let ties = InstinctRules.keepHighestConfidence(["a", "b", "c"], limit: 2, confidence: { _ in 0.8 })
        #expect(ties.kept == ["a", "b"] && ties.cut == 1)
    }

    // Due-date year rollover: a date before the source's day that was said as month and day only moves one year ahead.
    @Test func dueBeforeTheSourceWithAMonthAndDayMovesAYearAhead() {
        let src = instinctTestDate(2026, 11, 5)
        func roll(_ due: String?, _ quote: String) -> String? { InstinctRules.rolledDue(due, quote: quote, sourceTime: src) }
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
        func ok(_ q: String) -> Bool { InstinctRules.hasEvidence(kind: "fact", quote: q) }
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
        func ok(_ q: String) -> Bool { InstinctRules.hasEvidence(kind: "decision", quote: q) }
        #expect(ok("Okay, so we go with the weekly release train, that's settled."))
        #expect(ok("We are not renewing the licence, that is the final call."))
        #expect(ok("We will use Postgres for the ledger."))
        #expect(ok("We decided to use Postgres for the ledger."))
        #expect(ok("Wir haben das so entschieden."))
        #expect(!ok("I would not want to commit to anything right now."))
        #expect(!ok("Sounds good, let's do that."))
    }

    @Test func todosNeedNoMoreEvidence() {
        #expect(InstinctRules.hasEvidence(kind: "todo", quote: "anything at all"))
    }

    // Weekday resolution in code: the next such day strictly after the source's day, whatever the model said.
    @Test func weekdayInTheQuoteSetsTheNextOccurrence() {
        func due(_ quote: String, _ y: Int, _ m: Int, _ d: Int, model: String? = nil) -> String? {
            InstinctRules.weekdayDue(model, quote: quote, sourceTime: instinctTestDate(y, m, d))
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
