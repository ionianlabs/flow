import Foundation
import Testing
@testable import IonianFlow

extension IonianFlowTests {
@Suite struct VocabularyChecks {
    @Test func store() {
        let start = VocabularyParser.start, end = VocabularyParser.end
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ionian-flow-vocab-store-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let sample = VocabularyFile.template.replacingOccurrences(of: "## Terms\n", with: "## Terms\n- ACME\n- pull request (heard as: pool request)\n")
            + "\n\(start) x -->\n## From vault: Notes\n\n### People\n- Jana Weber\n- Lena\n\n### Products\n- Gemma\n\(end)\n"
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        let store = VocabularyStore(url: url, watch: false)
        func check(_ cond: Bool, _ what: String) { #expect(cond, "vocabulary: \(what)") }
        check(store.entries.map(\.text) == ["ACME", "pull request", "Jana Weber", "Lena", "Gemma"], "parse \(store.entries.map(\.text))")
        check(store.entries[1].aliases == ["pool request"], "aliases")
        store.remove(store.entries.first { $0.text == "Lena" }!)  // vault term: goes to Ignore
        check(store.ignored == ["Lena"] && !store.entries.contains { $0.text == "Lena" }, "remove vault term")
        store.add("Lena", category: "People")  // yours now: no longer ignored
        check(store.ignored.isEmpty && store.entries.contains { $0.text == "Lena" && $0.source == .mine }, "re-add")
        store.add("Data Garage", category: "Projects")  // new section
        check(store.entries.contains { $0.text == "Data Garage" && $0.category == "Projects" }, "new section")
        store.remove(store.entries.first { $0.text == "ACME" }!)
        check(!store.entries.contains { $0.text == "ACME" } && store.ignored.isEmpty, "remove own term")
        store.setDomain("logistics IT")
        check(store.domain == "logistics IT", "domain")
        let reread = VocabularyStore(url: url, watch: false)
        check(reread.entries.map(\.text) == store.entries.map(\.text), "round trip")
    }

    /// The asserts from vocab.py's __main__, with the same strings, plus cologne and the parser's edge cases.
    @Test func normalizer() {
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) { #expect(got == want, "normalizer: \(what)") }
        #expect(!WordFrequencyTable.shared.isEmpty, "wordfreq.tsv missing (app/Resources)")
        guard !WordFrequencyTable.shared.isEmpty else { return }

        let start = VocabularyParser.start, end = VocabularyParser.end
        var sample = VocabularyFile.template.replacingOccurrences(of: "## Terms\n", with: "## Terms\n- ACME\n- pull request (heard as: pool request, pul request)\n")
        sample = sample.replacingOccurrences(of: "## Ignore\n", with: "## Ignore\n- Helper\n")
        sample += "\n\(start) x -->\n## From vault: Notes\n### People\n- Jana Weber\n- ACME\n### Terms\n- Helper\n\(end)\n"
        var v = VocabularyParser.parse(sample)
        check(v.terms.map { "\($0.text)/\($0.isVault ? "vault" : "manual")" }, ["ACME/manual", "pull request/manual", "Jana Weber/vault"], "parse terms")
        check(v.ignored, ["Helper"], "ignore")
        var n = VocabNormalizer(v)
        check(n.normalize("the pool request and a Pool Request."), "the pull request and a pull request.", "alias")
        check(n.normalize("a whirlpool requester"), "a whirlpool requester", "alias boundary")

        n = VocabNormalizer(markdown: "## Terms\n- ToP\n- IonianFlow\n- Data Garage\n- Netvora\n- ETL\n- ACME\n")
        for (raw, want) in [
            ("the top shelf is full", "the top shelf is full"),
            ("an open flow of ideas, in Ionianflow", "an open flow of ideas, in IonianFlow"),
            ("im data garage und im Datagarage", "im Data Garage und im Data Garage"),
            ("Net vora baut für die acme", "Netvora baut für die ACME"),
            ("die E T L Planung", "die ETL Planung"),
        ] { check(n.normalize(raw), want, raw) }

        // Fuzzy: by spelling and by sound, and the guards.
        n = VocabNormalizer(markdown: "## Terms\n- Netvora\n- Jana Weber\n- Northwind Logistics\n- Gamma\n")
        for (raw, want) in [
            ("bei Netfora", "bei Netvora"),
            ("Jana Waber schrieb", "Jana Weber schrieb"),
            ("Northwind Logistic", "Northwind Logistics"),
            ("das Gamma Modell", "das Gamma Modell"),
            ("ein netvoraa", "ein Netvora"),
        ] { check(n.normalize(raw), want, raw) }

        check(FuzzyTerms.cologne("Meyer"), "67", "cologne Meyer")
        check(FuzzyTerms.cologne("Maier"), "67", "cologne Maier")
        check(FuzzyTerms.cologne("Müller-Lüdenscheidt"), FuzzyTerms.cologne("Mueller Ludenscheidt"), "cologne umlauts")
        check(FuzzyTerms.damerauLevenshtein(Array("ca".unicodeScalars), Array("abc".unicodeScalars)), 2, "unrestricted DL")

        // Parser edge cases shared with vocab.parse: CRLF, tab bullets, the first non-empty Domain line.
        v = VocabularyParser.parse("Domain:\r\nDomain: Logistics\r\n## Terms\r\n-\tACME\r\n* Jana (heard as: Jaana, Yana)\r\n---\r\n")
        check(v.domain, "Logistics", "domain")
        check(v.terms.map(\.text), ["ACME", "Jana"], "crlf and tab bullets")
        check(v.terms.last?.aliases ?? [], ["Jaana", "Yana"], "aliases")

        // Vault block: rewritten in place, domain filled once, old markers upgraded.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ionian-flow-vocab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Vocabulary.md")
        do {
            try VocabularyFile.writeVaultBlock(to: url, groups: [("People", ["Jana Weber"]), ("Acronyms", ["ToP"])], heading: "From vault: Notes", domain: "logistics IT")
            try VocabularyFile.writeVaultBlock(to: url, groups: [("People", ["Max Muster"])], heading: "From vault: Notes", domain: "something else")
            let w = VocabularyParser.parse(try String(contentsOf: url, encoding: .utf8))
            check(w.domain, "logistics IT", "vault domain")
            check(w.terms.map(\.text), ["Max Muster"], "vault block")
            try "Domain:\n## Terms\n- ACME\n<!-- openflow:vault:start x -->\n## old\n### People\n- Old\n<!-- openflow:vault:end -->\n".write(to: url, atomically: true, encoding: .utf8)
            try VocabularyFile.writeVaultBlock(to: url, groups: [("People", ["New"])], heading: "h")
            let text = try String(contentsOf: url, encoding: .utf8)
            check(text.contains("openflow"), false, "old marker upgraded")
            check(VocabularyParser.parse(text).terms.map(\.text), ["ACME", "New"], "old block replaced")
        } catch { Issue.record("normalizer: vault block: \(error)") }
    }
}
}
