import Foundation

// Unit F: `--enginetest-summary` and the model-free summary checks (clean_summary, chunks, prompts).

enum SummaryCLI {

    /// `--enginetest-summary --fixtures DIR --out DIR [--model-dir DIR]`: one <name>.swift.json per <name>.txt.
    static func cli(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let fixtures = value("--fixtures"), let out = value("--out") else {
            FileHandle.standardError.write(Data("usage: --enginetest-summary --fixtures DIR --out DIR [--model-dir DIR]\n".utf8))
            return 2
        }
        let dir = URL(fileURLWithPath: fixtures), outDir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tags = ((try? String(contentsOf: dir.appendingPathComponent("tags.txt"), encoding: .utf8)) ?? "")
            .components(separatedBy: ",").map(\.pyStrip).filter { !$0.isEmpty }
        let summarizer = value("--model-dir").map { Summarizer(llm: GemmaVaultLLM(directory: URL(fileURLWithPath: $0))) } ?? Summarizer()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixtures)) ?? []).filter { $0.hasSuffix(".txt") && $0 != "tags.txt" }.sorted()
        var rc: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for name in names {
                let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
                let s = await summarizer.summarize(transcript: text, tags: tags)
                let obj: [String: Any] = s.map { ["description": $0.description, "tags": $0.tags, "keywords": $0.keywords,
                                                  "points": $0.points, "decisions": $0.decisions, "actions": $0.actions] } ?? [:]
                let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
                try? data.write(to: outDir.appendingPathComponent(String(name.dropLast(4)) + ".swift.json"))
                print(name, "->", s?.description ?? "-")
                if s == nil { rc = 1 }
            }
            done.signal()
        }
        done.wait()
        return rc
    }
}
