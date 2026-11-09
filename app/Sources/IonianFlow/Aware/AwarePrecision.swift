import Foundation

/// `--aware-precision`: how many proposed items the user accepted, from the archived day files (spec F2).
enum AwarePrecision {
    /// One line per category (todo, decision, fact) with marked lines, then `unreviewed <n>`.
    static func report(archive: URL) -> String {
        var accepted: [String: Int] = [:], total: [String: Int] = [:], dups: [String: Int] = [:]
        var unreviewed = 0
        for url in BrainLines.awareFiles(in: archive) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for raw in text.components(separatedBy: .newlines) {
                guard let l = AwareLineText.parse(raw) else { continue }
                switch l.mark {
                case "x", "~": accepted[l.category, default: 0] += 1; total[l.category, default: 0] += 1
                case "-": total[l.category, default: 0] += 1
                case "=": total[l.category, default: 0] += 1; dups[l.category, default: 0] += 1
                case " ": unreviewed += 1
                default: break
                }
            }
        }
        var out: [String] = []
        for cat in AwareLineText.categories {
            guard let n = total[cat], n > 0 else { continue }
            let a = accepted[cat, default: 0]
            let pct = Int((Double(a) * 100 / Double(n)).rounded())
            out.append("\(cat) \(a)/\(n) \(pct)% duplicates \(dups[cat, default: 0])")
        }
        out.append("unreviewed \(unreviewed)")
        return out.joined(separator: "\n")
    }

    /// `--brain DIR` or the vault; nil when the archive folder does not exist.
    static func archive(args: [String], vault: URL?) -> URL? {
        var brain = vault
        if let i = args.firstIndex(of: "--brain"), i + 1 < args.count { brain = URL(fileURLWithPath: args[i + 1], isDirectory: true) }
        guard let dir = brain?.appendingPathComponent("_archive/inbox") else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    static func cli(_ args: [String]) -> Int32 {
        guard let dir = archive(args: args, vault: Settings.vault) else { print("no brain"); return 1 }
        print(report(archive: dir))
        return 0
    }
}
