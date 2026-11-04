import Foundation

// Unit F (vault sweep). Port of the former Python sweep.py: rule pipeline plus LLM extraction (2,000-character chunks),
// ranking (2+ notes, MIN_SCORE 2.5, recency, merge_variants, limit 120, 25 new per run), domain line,
// rules-only fallback, a cache file of its own, pause/resume via task cancellation and SweepControl.
// Writes through VocabularyFile.writeVaultBlock. The rules are in VaultSweepRules.swift, the ranking in
// VaultSweepRank.swift. The vault is only read.

enum VaultSweep {
    static let modelID = "mlx-community/gemma-4-e2b-it-4bit"
    /// Not the Python sweep's file (sweep-cache.json): its notes are read again once after the switch.
    static let cacheVersion = 1
    static var defaultCache: URL {
        Settings.testDir?.appendingPathComponent("vault-sweep.json")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ionian Flow/vault-sweep.json")
    }

    static let domainPrompt = #"""
Here are terms and note titles from one person's notes. Describe their professional domain
in at most 12 words, naming the industry and employer if they are obvious, e.g. "IT and data
analytics at a shipping company". Answer with the description only.
"""#

    static let extractPrompt = #"""
You read one note and list every name a speech recognizer might not know:
people, organizations, teams, projects, products and tools, acronyms, domain jargon.
Only names that are written in the note; copy them exactly as written. No ordinary words or
phrases, no headings, no dates, no ticket numbers, no file names. A person is a specific
individual's name, never a role or job title (not "Analyst", "Product Owner", "Speaker", "You").

Answer with one line per name: <category>: <name>
Categories: person, organization, project, product, acronym, term

Example note: "Workshop with Lena on the LumAI roadmap. Initech hands over the TaskBoard board."
Answer:
person: Lena
project: LumAI
organization: Initech
product: TaskBoard
"""#

    struct Options {
        var vault: URL
        var out: URL
        var cache: URL = VaultSweep.defaultCache
        var limit = 120
        var maxNew = 25
        /// The model's name when the LLM reads the notes; nil: rules only.
        var model: String?
        /// Unix time for the recency of notes (tests); nil: now.
        var now: Double?
        /// "yyyy-MM-dd" for the heading (tests); nil: today.
        var today: String?
    }

    struct Result { var added: Int, removed: Int, total: Int, seconds: Double }
    enum Progress { case reading(done: Int, of: Int), learning(done: Int, of: Int) }

    struct NoteEntry: Codable {
        var rel: String
        var mtime: Double
        var model: String?
        var terms: [SweepTerm]
    }

    struct Cache: Codable {
        var version: Int
        var vault: String
        var notes: [NoteEntry]
    }

    /// Absolute paths of the vault's notes, sorted: os.walk without hidden folders and SKIP_DIRS.
    static func notePaths(in vault: String) -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        func walk(_ dir: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                let path = dir + "/" + name
                var st = stat(), lst = stat()
                guard lstat(path, &lst) == 0 else { continue }
                let isLink = (lst.st_mode & S_IFMT) == S_IFLNK
                let isDir = (stat(path, &st) == 0) && (st.st_mode & S_IFMT) == S_IFDIR
                if isDir {
                    if !isLink, !name.hasPrefix("."), !SweepRules.skipDirs.contains(name.lowercased()) { walk(path) }
                } else if name.hasSuffix(".md") {
                    paths.append(path)
                }
            }
        }
        walk(vault)
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func modificationTime(_ path: String) -> Double? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
    }

    static func loadCache(_ url: URL, vault: String) -> Cache? {
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Cache.self, from: data),
              c.version == cacheVersion, c.vault == vault else { return nil }
        return c
    }

    static func saveCache(_ cache: Cache, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
    }

    /// One sweep. `makeLLM` is called on the first note that needs the model (nil or a throw: rules only).
    /// Cancelling the task stops it after saving what was read; `control` pauses it between notes and tokens.
    static func run(_ o: Options, makeLLM: (() async throws -> VaultLLM)? = nil, control: SweepControl? = nil,
                    progress: ((Progress) -> Void)? = nil) async throws -> Result {
        let t0 = Date()
        var vaultPath = o.vault.standardizedFileURL.path
        while vaultPath.count > 1, vaultPath.hasSuffix("/") { vaultPath.removeLast() }
        let cache = loadCache(o.cache, vault: vaultPath)
        let old = Dictionary((cache?.notes ?? []).map { ($0.rel, $0) }, uniquingKeysWith: { $1 })

        var llm: VaultLLM?, tried = false
        func loadLLM() async -> VaultLLM? {
            if !tried {
                tried = true
                if let make = makeLLM {
                    do { llm = try await make() } catch { NSLog("Ionian Flow: can't load the sweep model (%@), using rules only", "\(error)") }
                }
            }
            return llm
        }

        let paths = notePaths(in: vaultPath)
        var notes: [NoteEntry] = []
        var newReads = 0
        func checkpoint(visited: Int) {
            let seen = Set(notes.map(\.rel))
            let rest = (cache?.notes ?? []).filter { !seen.contains($0.rel) }
            saveCache(Cache(version: cacheVersion, vault: vaultPath, notes: notes + rest), to: o.cache)
        }
        do {
            for (i, path) in paths.enumerated() {
                try Task.checkCancellation()
                await control?.waitWhilePaused()
                try Task.checkCancellation()
                let rel = String(path.dropFirst(vaultPath.count + 1))
                guard let mtime = modificationTime(path) else { continue }
                if let e = old[rel], e.mtime == mtime, e.model == o.model {
                    notes.append(e)
                } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    let text = String(decoding: data, as: UTF8.self).universalNewlines
                    let model = o.model != nil ? await loadLLM() : nil
                    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    if SweepRules.transcript.matchAtStart(text) != nil {  // Ionian Flow's own output: learning from it repeats its mistakes
                        notes.append(NoteEntry(rel: rel, mtime: mtime, model: model != nil ? o.model : nil, terms: []))
                    } else if let model {
                        progress?(.learning(done: i + 1, of: paths.count))
                        let terms = try await SweepRules.extract(text) { try await model.ask(extractPrompt, $0, maxTokens: 400) }
                        notes.append(NoteEntry(rel: rel, mtime: mtime, model: o.model, terms: terms))
                        newReads += 1
                        if newReads % 25 == 0 { checkpoint(visited: i) }
                    } else {
                        notes.append(NoteEntry(rel: rel, mtime: mtime, model: nil, terms: SweepRules.extractRules(text, stem: stem)))
                    }
                }
                progress?(.reading(done: i + 1, of: paths.count))
            }
        } catch {
            checkpoint(visited: notes.count)
            throw error
        }

        let current = VocabularyParser.parse((try? String(contentsOf: o.out, encoding: .utf8)) ?? "")
        let mine = Set(current.terms.filter { !$0.isVault }.map { $0.text.lowercased() } + current.ignored.map { $0.lowercased() })
        let before = Set(current.terms.filter(\.isVault).map { $0.text.lowercased() })
        var kept: [RankedTerm] = []
        var new = 0
        let ranked = SweepRank.rank(notes.map { ($0.mtime, $0.terms) }, now: o.now ?? Date().timeIntervalSince1970)
        for t in ranked {  // best first: terms already in the file keep their place, new ones are capped
            if mine.contains(t.term.lowercased()) || kept.count >= o.limit { continue }
            if !before.contains(t.term.lowercased()) {
                if new >= o.maxNew { continue }
                new += 1
            }
            kept.append(t)
        }
        let groups = SweepRules.categories.map { c in (category: c, terms: kept.filter { $0.category == c }.map(\.term)) }
        var domain = ""
        if current.domain.isEmpty, o.model != nil, let model = await loadLLM() {
            domain = try await describeDomain(model, groups: groups, notes: notes.map(\.rel))
        }
        let after = Set(kept.map { $0.term.lowercased() })
        let name = vaultPath.split(separator: "/").last.map(String.init) ?? vaultPath
        try VocabularyFile.writeVaultBlock(to: o.out, groups: groups, heading: "From vault: \(name) (\(o.today ?? today()))", domain: domain)
        saveCache(Cache(version: cacheVersion, vault: vaultPath, notes: notes), to: o.cache)
        return Result(added: after.subtracting(before).count, removed: before.subtracting(after).count, total: kept.count,
                      seconds: Date().timeIntervalSince(t0))
    }

    static func describeDomain(_ llm: VaultLLM, groups: [(category: String, terms: [String])], notes: [String]) async throws -> String {
        let titles = notes.prefix(40).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        var user = groups.filter { !$0.terms.isEmpty }.map { "\($0.category): \($0.terms.prefix(15).joined(separator: ", "))" }.joined(separator: "\n")
        user += "\nNote titles: " + titles.joined(separator: ", ")
        let answer = try await llm.ask(domainPrompt, user, maxTokens: 40).pyStrip
        guard let line = VocabularyParser.splitLines(answer).first else { return "" }
        return line.pyStrip(chars: " .\"'")
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: --enginetest-sweep

    /// `--enginetest-sweep --vault DIR --out FILE [--cache FILE] [--no-llm] [--model-dir DIR] [--now EPOCH] [--today YYYY-MM-DD]
    /// [--limit N] [--max-new N]`: one sweep, the way sweep.py runs. Without --model-dir the hub's Gemma is used.
    static func cli(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let vault = value("--vault"), let out = value("--out") else {
            FileHandle.standardError.write(Data("usage: --enginetest-sweep --vault DIR --out FILE [--cache FILE] [--no-llm] [--model-dir DIR]\n".utf8))
            return 2
        }
        var o = Options(vault: URL(fileURLWithPath: (vault as NSString).expandingTildeInPath),
                        out: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        if let c = value("--cache") { o.cache = URL(fileURLWithPath: (c as NSString).expandingTildeInPath) }
        o.limit = value("--limit").flatMap(Int.init) ?? 120
        o.maxNew = value("--max-new").flatMap(Int.init) ?? 25
        o.now = value("--now").flatMap(Double.init)
        o.today = value("--today")
        let dir = value("--model-dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var make: (() async throws -> VaultLLM)?
        if !args.contains("--no-llm") {
            o.model = modelID
            make = { dir.map { GemmaVaultLLM(directory: $0) } ?? GemmaVaultLLM() }
        }
        var rc: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .background) {
            do {
                let r = try await run(o, makeLLM: make) { p in
                    if case .reading(let d, let n) = p { print("progress \(d) \(n)") }
                }
                print(String(format: "done added=%d removed=%d total=%d seconds=%.1f", r.added, r.removed, r.total, r.seconds))
            } catch {
                FileHandle.standardError.write(Data("sweep failed: \(error)\n".utf8))
                rc = 1
            }
            done.signal()
        }
        done.wait()
        return rc
    }
}
