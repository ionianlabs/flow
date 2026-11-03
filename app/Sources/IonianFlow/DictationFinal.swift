import Foundation

// Unit C (dictation final). Whole-utterance final for dictation: Parakeet Ultra, CTC vocabulary rescoring,
// common-word guard (zipf 4.0), then VocabNormalizer. Models come from ModelHub.parakeet().
// FinalPass.swift (transcription mode) delegates to the same shared Parakeet.

protocol UtteranceFinalizer {
    /// pcm: 16 kHz mono Float. lang: "de"/"en"/nil (auto).
    func finalize(pcm: [Float], lang: String?) async -> String
}

/// The production finalizer. Runs its model work through `hub.serial`.
final class ParakeetFinalizer: UtteranceFinalizer {
    init(hub: ModelHub = .shared) {}
    func finalize(pcm: [Float], lang: String?) async -> String { fatalError("Unit C") }
    /// Rebuild the CTC vocabulary session after the vocabulary file changed.
    func reloadVocabulary() {}
}

enum DictationFinal {
    /// `--enginetest-dictation ...`. Return the process exit code.
    static func cli(_ args: [String]) -> Int32 { FileHandle.standardError.write(Data("not implemented\n".utf8)); return 2 }
}
