import Foundation

// Unit 0 (skeleton). Routes the --enginetest-* flags to the owning unit's entry point and runs the units'
// model-free self tests. Each unit only changes its own file; this file changes only when a flag is added.

enum EngineCLI {
    /// Returns an exit code when `args` holds an engine test flag, nil otherwise (the app starts normally).
    static func run(_ args: [String]) -> Int32? {
        let routes: [(String, ([String]) -> Int32)] = [
            ("--enginetest-live", NativeLive.cli),            // B
            ("--enginetest-dictation", DictationFinal.cli),   // C
            ("--enginetest-hub", ModelHubTests.cli),          // D
            ("--enginetest-polish", PolisherCLI.cli),         // E
            ("--enginetest-summary", SummarizerCLI.cli),      // F
            ("--enginetest-sweep", VaultSweep.cli),           // F
            ("--enginetest-store", ModelStoreTests.cli),      // G
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

enum EngineSelfTests {
    /// Model-free tests of every unit; true when all pass (all run, no short-circuit).
    static func all() -> Bool {
        let results = [
            NativeLive.selfTest(),       // B
            FinalizerSelfTest.run(),     // C
            ModelHubTests.selfTest(),    // D
            PolisherSelfTest.run(),      // E
            SummarizerCLI.selfTest(),    // F
            VaultSweep.selfTest(),       // F
            ModelStoreTests.selfTest(),  // G
            WERScore.selfTest(),         // WER scoring
            ModelSetupModel.selfTest(),  // H
        ]
        return !results.contains(false)
    }
}
