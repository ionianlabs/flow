import Foundation

// Unit F: a small JSON reader that keeps object keys in file order and follows Python's json.loads and
// str() where clean_summary depends on them (JSONSerialization loses the key order of a dict item).

indirect enum PyJSON {
    case null, bool(Bool), int(Int), double(Double), string(String), array([PyJSON]), object([(String, PyJSON)])

    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    subscript(key: String) -> PyJSON? {
        if case .object(let o) = self { return o.first { $0.0 == key }?.1 }
        return nil
    }

    /// Python's str(): what an unexpected item becomes in a list of strings.
    var pyStr: String {
        switch self {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
        case .string(let s): return s
        case .array(let a): return "[" + a.map(\.pyRepr).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.map { "'\($0.0)': \($0.1.pyRepr)" }.joined(separator: ", ") + "}"
        }
    }

    private var pyRepr: String {
        if case .string(let s) = self { return "'\(s)'" }
        return pyStr
    }

    /// json.loads: nil where Python raises.
    static func parse(_ text: String) -> PyJSON? {
        var p = Parser(Array(text.unicodeScalars))
        guard let v = p.value() else { return nil }
        p.skipSpace()
        return p.i == p.s.count ? v : nil
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skipSpace() { while i < s.count, " \t\n\r".unicodeScalars.contains(s[i]) { i += 1 } }

        mutating func literal(_ w: String) -> Bool {
            let u = Array(w.unicodeScalars)
            guard i + u.count <= s.count, Array(s[i..<i + u.count]) == u else { return false }
            i += u.count
            return true
        }

        mutating func value() -> PyJSON? {
            skipSpace()
            guard i < s.count else { return nil }
            switch s[i] {
            case "{":
                i += 1
                var out: [(String, PyJSON)] = []
                skipSpace()
                if i < s.count, s[i] == "}" { i += 1; return .object(out) }
                while true {
                    skipSpace()
                    guard i < s.count, s[i] == "\"", let k = string() else { return nil }
                    skipSpace()
                    guard i < s.count, s[i] == ":" else { return nil }
                    i += 1
                    guard let v = value() else { return nil }
                    if let at = out.firstIndex(where: { $0.0 == k }) { out[at].1 = v } else { out.append((k, v)) }
                    skipSpace()
                    guard i < s.count else { return nil }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "}" { i += 1; return .object(out) }
                    return nil
                }
            case "[":
                i += 1
                var out: [PyJSON] = []
                skipSpace()
                if i < s.count, s[i] == "]" { i += 1; return .array(out) }
                while true {
                    guard let v = value() else { return nil }
                    out.append(v)
                    skipSpace()
                    guard i < s.count else { return nil }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "]" { i += 1; return .array(out) }
                    return nil
                }
            case "\"": return string().map { .string($0) }
            case "t": return literal("true") ? .bool(true) : nil
            case "f": return literal("false") ? .bool(false) : nil
            case "n": return literal("null") ? .null : nil
            default: return number()
            }
        }

        mutating func number() -> PyJSON? {
            let start = i
            func digits() -> Bool { let b = i; while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }; return i > b }
            if i < s.count, s[i] == "-" { i += 1 }
            guard i < s.count else { return nil }
            if s[i] == "0" { i += 1 } else if !digits() { return nil }
            var isFloat = false
            if i < s.count, s[i] == "." { i += 1; isFloat = true; if !digits() { return nil } }
            if i < s.count, s[i] == "e" || s[i] == "E" {
                i += 1; isFloat = true
                if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
                if !digits() { return nil }
            }
            var v = String.UnicodeScalarView()
            v.append(contentsOf: s[start..<i])
            let t = String(v)
            if !isFloat, let n = Int(t) { return .int(n) }
            return Double(t).map { .double($0) }
        }

        mutating func string() -> String? {
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                i += 1
                if c == "\"" { return String(out) }
                if c.value < 0x20 { return nil }  // strict, like Python
                guard c == "\\" else { out.append(c); continue }
                guard i < s.count else { return nil }
                let e = s[i]
                i += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{c}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard var code = hex4() else { return nil }
                    if (0xD800..<0xDC00).contains(code), i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
                        let save = i
                        i += 2
                        if let lo = hex4(), (0xDC00..<0xE000).contains(lo) { code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00) } else { i = save }
                    }
                    out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: return nil
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= s.count else { return nil }
            var v = String.UnicodeScalarView()
            v.append(contentsOf: s[i..<i + 4])
            guard let n = UInt32(String(v), radix: 16) else { return nil }
            i += 4
            return n
        }
    }
}
