import Foundation

// Unit F helpers: Python's `re` and `str` semantics where the vault sweep and the summary depend on them.
// Offsets in SweepRe.M are UTF-16 (NSString); callers only slice with them, never count characters.

struct SweepRe {
    let re: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    struct M {
        let s: NSString
        let r: NSTextCheckingResult
        var start: Int { r.range.location }
        var end: Int { NSMaxRange(r.range) }
        var whole: String { s.substring(with: r.range) }
        /// A group's text; nil when it didn't take part (Python's None).
        func group(_ i: Int) -> String? {
            let g = r.range(at: i)
            return g.location == NSNotFound ? nil : s.substring(with: g)
        }
    }

    func all(_ text: String) -> [M] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { M(s: ns, r: $0) }
    }

    func first(_ text: String) -> M? {
        let ns = text as NSString
        return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).map { M(s: ns, r: $0) }
    }

    /// re.match: anchored at the start.
    func matchAtStart(_ text: String) -> M? {
        let ns = text as NSString
        return re.firstMatch(in: text, options: .anchored, range: NSRange(location: 0, length: ns.length)).map { M(s: ns, r: $0) }
    }

    func test(_ text: String) -> Bool { first(text) != nil }

    /// re.sub with a function.
    func sub(_ text: String, _ f: (M) -> String) -> String {
        let ns = text as NSString
        var out = "", pos = 0
        for m in all(text) {
            out += ns.substring(with: NSRange(location: pos, length: m.start - pos)) + f(m)
            pos = m.end
        }
        return out + ns.substring(from: pos)
    }

    func sub(_ text: String, _ replacement: String) -> String { sub(text) { _ in replacement } }

    /// re.split without groups (empty pieces kept).
    func split(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = [], pos = 0
        for m in all(text) {
            out.append(ns.substring(with: NSRange(location: pos, length: m.start - pos)))
            pos = m.end
        }
        out.append(ns.substring(from: pos))
        return out
    }
}

extension String {
    /// Code points, as Python's len().
    var cpCount: Int { unicodeScalars.count }

    func pyStrip(chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        let u = Array(unicodeScalars)
        var a = 0, b = u.count
        while a < b, set.contains(u[a]) { a += 1 }
        while b > a, set.contains(u[b - 1]) { b -= 1 }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: u[a..<b])
        return String(v)
    }

    /// s[:n] by code points.
    func cpPrefix(_ n: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: unicodeScalars.prefix(n))
        return String(v)
    }

    func cpDropFirst(_ n: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: unicodeScalars.dropFirst(n))
        return String(v)
    }

    /// Python's `needle in self` (literal, no canonical equivalence).
    func pyContains(_ needle: String) -> Bool {
        needle.isEmpty || range(of: needle, options: .literal) != nil
    }

    private func casing() -> (cased: Bool, upper: Bool, lower: Bool) {
        var cased = false, upper = true, lower = true
        for u in unicodeScalars {
            let p = u.properties
            if p.isUppercase || p.generalCategory == .titlecaseLetter {
                cased = true; lower = false
                if p.generalCategory == .titlecaseLetter { upper = false }
            } else if p.isLowercase && p.generalCategory == .lowercaseLetter {
                cased = true; upper = false
            }
        }
        return (cased, upper, lower)
    }

    /// str.isupper()
    var pyIsUpper: Bool { let c = casing(); return c.cased && c.upper }
    /// str.islower()
    var pyIsLower: Bool { let c = casing(); return c.cased && c.lower }
    /// str.isdigit()
    var pyIsDigit: Bool {
        !isEmpty && unicodeScalars.allSatisfy { $0.properties.numericType == .decimal || $0.properties.numericType == .digit }
    }
    var pyIsAlpha: Bool {
        !isEmpty && unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }
    }
    /// str.split() on whitespace.
    var pySplit: [String] {
        var out: [String] = [], cur = String.UnicodeScalarView()
        for u in unicodeScalars {
            if u.isPySpace { if !cur.isEmpty { out.append(String(cur)); cur = .init() } } else { cur.append(u) }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    /// Text as Python's universal-newline `open()` reads it.
    var universalNewlines: String {
        guard unicodeScalars.contains("\r") else { return self }  // not contains(): "\r\n" is one Character
        return replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// A dict that remembers insertion order (Python's), for the places where ties break by it.
struct OMap<V> {
    private(set) var keys: [String] = []
    private var dict: [String: V] = [:]
    subscript(key: String) -> V? {
        get { dict[key] }
        set {
            if let v = newValue {
                if dict[key] == nil { keys.append(key) }
                dict[key] = v
            }
        }
    }
    var count: Int { keys.count }
    var values: [V] { keys.map { dict[$0]! } }
    var pairs: [(String, V)] { keys.map { ($0, dict[$0]!) } }
    mutating func update(_ key: String, default d: @autoclosure () -> V, _ f: (inout V) -> Void) {
        var v = dict[key] ?? d()
        f(&v)
        self[key] = v
    }
}

/// Counter with Python's insertion-order tie-breaking for most_common(1).
struct OCounter {
    private var map = OMap<Int>()
    mutating func add(_ key: String, _ n: Int = 1) { map.update(key, default: 0) { $0 += n } }
    var top: String? {
        var best: (String, Int)?
        for (k, v) in map.pairs where best == nil || v > best!.1 { best = (k, v) }
        return best?.0
    }
}
