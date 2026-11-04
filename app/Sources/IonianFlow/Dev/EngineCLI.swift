import Foundation

// Unit 0 (skeleton). Routes the --enginetest-* flags to the owning unit's entry point. (The model-free
// self tests are in Tests/IonianFlowTests: `swift test --package-path app`.) Each unit only changes its own file; this file changes only when a flag is added.

enum EngineCLI {
    /// Returns an exit code when `args` holds an engine test flag, nil otherwise (the app starts normally).
    static func run(_ args: [String]) -> Int32? {
        let routes: [(String, ([String]) -> Int32)] = [
            ("--enginetest-live", NativeLive.cli),            // B
            ("--enginetest-dictation", DictationFinal.cli),   // C
            ("--enginetest-hub", ModelHubCLI.cli),          // D
            ("--enginetest-polish", PolisherCLI.cli),         // E
            ("--enginetest-summary", SummarizerCLI.cli),      // F
            ("--enginetest-sweep", VaultSweep.cli),           // F
            ("--enginetest-store", ModelStoreCLI.cli),      // G
            ("--e2e-engine", E2E.cli),                        // integration
            ("--score-dictation", WERScore.scoreDictationCLI),
            ("--compare-transcribe", WERScore.compareTranscribeCLI),
            ("--segment-replay", { SegmenterReplay.cli($0) }),
            ("--make-two-speaker", WERScore.makeTwoSpeakerCLI),
        ]
        for (flag, handler) in routes {
            if let i = args.firstIndex(of: flag) { return handler(Array(args[(i + 1)...])) }
        }
        return nil
    }
}
