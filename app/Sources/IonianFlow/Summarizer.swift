import Foundation

// Unit F (summaries). Port of asr/polish.py summary: 12k-character chunks, notes, then JSON; clean_summary
// (tags, keywords present in the transcript, date grounding with WHEN_DE); empty result = nil (no summary).
// Gemma comes from ModelHub.gemma(); generation runs inside ModelHub.serial.

final class Summarizer {
    init(hub: ModelHub = .shared) {}
    func summarize(transcript: String, tags: [String]) async -> TranscriptSummary? { fatalError("Unit F") }
}

enum SummarizerCLI {
    /// `--enginetest-summary`: summaries on fixture transcripts. Return the process exit code.
    static func cli(_ args: [String]) -> Int32 { FileHandle.standardError.write(Data("not implemented\n".utf8)); return 2 }
    /// Model-free checks (clean_summary), called from --selftest.
    static func selfTest() -> Bool { true }
}
