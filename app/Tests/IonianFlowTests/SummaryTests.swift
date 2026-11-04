import Foundation
import Testing
@testable import IonianFlow

// Unit F: the model-free summary checks (clean_summary, chunks, prompts).

extension IonianFlowTests {
@Suite struct SummaryChecks {
    @Test func matchesReference() {
        func check(_ cond: Bool, _ what: String) { #expect(cond, "\(what)") }
        let e = VaultSweepFixtures.expected
        #expect(!e.isEmpty, "expected values unreadable")
        guard !e.isEmpty else { return }
        let h = e["hashes"] as! [String: String]
        check(VaultSweepFixtures.sha(Summarizer.summarySystem) == h["summary"], "summary prompt differs from polish.py")
        check(VaultSweepFixtures.sha(Summarizer.notesSystem) == h["notes"], "notes prompt differs from polish.py")
        let sc = e["sumchunks"] as! [String: Any]
        check(Summarizer.chunks(sc["text"] as! String, sc["size"] as! Int) == sc["parts"] as! [String], "chunks")
        for (i, s) in (e["summaries"] as! [[String: Any]]).enumerated() {
            let got = Summarizer.cleanSummary(s["raw"] as! String, transcript: s["transcript"] as! String)
            let normalized = (try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: got))) as? NSDictionary ?? [:]
            check(normalized == (s["clean"] as! NSDictionary), "clean_summary case \(i): \(got) vs \(s["clean"]!)")
        }
        let empty = Summarizer.cleanSummary(#"{"description": "", "points": []}"#, transcript: "x")
        check(empty.isEmpty && TranscriptSummary(empty) == nil, "empty result means no summary")
    }
}
}
