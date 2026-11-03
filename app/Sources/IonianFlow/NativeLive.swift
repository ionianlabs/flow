import Foundation

// Unit B (live). Streaming Nemotron: one LiveStream per session (cuts at sample/1280 frames, PUNCT_HOLD 8,
// leading-punctuation strip, Latin-only, flush padding, segment times, language tag, live bias).
// Also the --enginetest-live entry point (WER, latency, mixed language; lifts scripts/engine-bench).

final class LiveStream {
    init(id: SessionID, options: SessionOptions) {}
}

enum NativeLive {
    /// `--enginetest-live ...`. Return the process exit code.
    static func cli(_ args: [String]) -> Int32 { FileHandle.standardError.write(Data("not implemented\n".utf8)); return 2 }
    /// Fast checks without models, called from --selftest.
    static func selfTest() -> Bool { true }
}
