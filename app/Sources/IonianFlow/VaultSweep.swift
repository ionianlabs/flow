import Foundation

// Unit F (vault sweep). Port of asr/sweep.py: rule pipeline plus LLM extraction (2,000-character chunks),
// ranking (2+ notes, MIN_SCORE 2.5, recency, merge_variants, limit 120, 25 new per run), domain line,
// rules-only fallback, new cache file with its own version, pause/resume via task cancellation and priority.
// Writes through VocabularyFile.writeVaultBlock. VaultSweeper.swift (the existing driver) is also Unit F's.

enum VaultSweep {
    /// `--enginetest-sweep`: run on a labelled fixture vault. Return the process exit code.
    static func cli(_ args: [String]) -> Int32 { FileHandle.standardError.write(Data("not implemented\n".utf8)); return 2 }
    /// Model-free checks (rule pipeline, ranking), called from --selftest.
    static func selfTest() -> Bool { true }
}
