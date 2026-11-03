import Foundation

// Unit E (cleanup). Port of asr/polish.py polish: prompts, few-shot examples, glossary (domain + up to 15 terms
// by trigram Jaccard >= 0.3), previous-segment context, every finish() guard, preload, the n-1 prefill rule.
// Gemma comes from ModelHub.gemma(); every generation runs inside ModelHub.serial.

final class Polisher {
    init(hub: ModelHub = .shared) {}
    /// Load and warm the model (the "id 0 + empty text" preload).
    func preload() async { fatalError("Unit E") }
    /// nil when cleanup is unavailable or a guard rejected the output (the caller keeps the original).
    func polish(text: String, before: String) async -> String? { fatalError("Unit E") }
}

enum PolisherCLI {
    /// `--enginetest-polish`: JSON lines on stdin/stdout, compatible with asr/bench_llm.py's `swift:` backend
    /// (the protocol of scripts/llm-bench main.swift). Return the process exit code.
    static func cli(_ args: [String]) -> Int32 { FileHandle.standardError.write(Data("not implemented\n".utf8)); return 2 }
}
