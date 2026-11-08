import Foundation

/// The duplicate check for one candidate item (spec F1.22 to F1.26).
struct AwareDedup {
    enum Result: Equatable {
        case duplicate
        case keep(AwareItem)
    }

    var model: AwareModel

    /// `earlier` are the items kept before this one in the same sweep (F1.25).
    func check(_ item: AwareItem, against lines: [BrainLine], earlier: [AwareItem]) async -> Result {
        let texts = lines.map(\.text) + earlier.map(\.text)
        let ranked = AwareRules.rankByOverlap(item: item.text, lines: texts)
        if ranked.duplicate { return .duplicate }
        guard !ranked.top.isEmpty else { return .keep(item) }
        // A model error must not lose the item.
        guard let verdict = try? await model.judge(item, against: ranked.top.map(\.line)) else { return .keep(item) }
        switch verdict {
        case .same: return .duplicate
        case .conflicts(let line):
            var kept = item
            kept.conflicts = line
            return .keep(kept)
        case .new: return .keep(item)
        }
    }
}
