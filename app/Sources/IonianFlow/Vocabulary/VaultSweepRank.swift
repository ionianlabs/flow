import Foundation

// Unit F: rank(), merge_variants() and one_edit() of the former Python sweep.py.

struct RankedTerm: Equatable {
    var term: String
    var category: String
    var notes: Int
    var count: Int
    var alias: Bool
    var recency: Double
    var score: Double
}

enum SweepRank {
    static let minScore = 2.5  // two notes with a couple of mentions each, or one alias in a fresh note

    /// One entry per term (spellings merged, the most frequent wins; the category by majority), best first.
    /// A term from a single note has to be an alias, a title or a link text. `notes` in file order.
    static func rank(_ notes: [(mtime: Double, terms: [SweepTerm])], now: Double) -> [RankedTerm] {
        struct Acc {
            var spellings = OCounter(), categories = OCounter()
            var notes = 0, count = 0
            var alias = false
            var recency = 0.0
        }
        var terms = OMap<Acc>()
        for note in notes {
            let recency = exp(-max(0.0, now - note.mtime) / 86400 / 90)
            for e in note.terms {
                guard e.alias && SweepRules.wellFormed(e.term) || SweepRules.plausible(e.term, e.category, lowercaseToo: e.lower) else { continue }
                terms.update(e.term.lowercased(), default: Acc()) { t in
                    t.spellings.add(e.term, e.count)
                    t.categories.add(e.category)
                    t.notes += 1
                    t.count += e.count
                    t.alias = t.alias || e.alias
                    t.recency = max(t.recency, recency)
                }
            }
        }
        var ranked: [RankedTerm] = []
        for t in terms.values {
            if t.notes < 2 && !t.alias { continue }
            let score = (1 + log(Double(t.notes))) * (1 + log(Double(t.count))) * (0.25 + t.recency) * (t.alias ? 1.5 : 1)
            if score < minScore { continue }
            ranked.append(RankedTerm(term: t.spellings.top!, category: t.categories.top!, notes: t.notes, count: t.count,
                                     alias: t.alias, recency: t.recency, score: score))
        }
        return mergeVariants(stableSort(ranked) { $0.score > $1.score })
    }

    /// a and b differ by one substituted, inserted or deleted letter.
    static func oneEdit(_ x: String, _ y: String) -> Bool {
        var a = Array(x.unicodeScalars), b = Array(y.unicodeScalars)
        if abs(a.count - b.count) > 1 || a == b { return false }
        if a.count > b.count { swap(&a, &b) }
        let i = (0..<a.count).first { a[$0] != b[$0] } ?? a.count
        return Array(a[min(a.count, i + (a.count == b.count ? 1 : 0))...]) == Array(b[min(b.count, i + 1)...])
    }

    /// Drops a name one letter away from a much more frequent one of the same kind: "Pavez" and "Tomes"
    /// are typos of "Pavel". Two real people ("Jona", "Jonas") both stay frequent.
    static func mergeVariants(_ ranked: [RankedTerm]) -> [RankedTerm] {
        var kept: [RankedTerm] = []
        for t in stableSort(ranked, by: { $0.count > $1.count }) {
            if t.term.cpCount >= 4, kept.contains(where: {
                $0.category == t.category && $0.count >= 3 * t.count && oneEdit($0.term.lowercased(), t.term.lowercased())
            }) { continue }
            kept.append(t)
        }
        return stableSort(kept) { $0.score > $1.score }
    }

    /// Python's sort is stable; so is this, whatever the standard library promises.
    static func stableSort<T>(_ a: [T], by before: (T, T) -> Bool) -> [T] {
        a.enumerated().sorted { before($0.element, $1.element) || (!before($1.element, $0.element) && $0.offset < $1.offset) }.map(\.element)
    }
}
