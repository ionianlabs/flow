import Foundation
import Testing
@testable import IonianFlow

/// Segmenter tests: the energy gate on normal-level tone bursts (no model needed), and the VAD on a real
/// clip from samples/ turned down to RMS ~0.001, where the energy gate is deaf. The VAD cases need the Silero
/// model and the clip, so they only run with IONIAN_FLOW_MODEL_TESTS=1.
extension IonianFlowTests {
@Suite struct SegmenterCuts {
    private static func cuts(_ pcm: [Int16], energy: Bool) -> [SegmenterReplay.Cut] {
        SegmenterReplay.run(pcm, energy: energy, settings: Segmenter.Settings())
    }

    @Test func energyGate() {
        // Energy gate: 3 s of a 0.1-level tone, then 3 s of silence -> a cut in the middle of the pause.
        let tone = (0..<48_000).map { Int16(0.1 * 32767 * sin(Double($0) * 2 * .pi * 220 / 16_000)) }
        let silence = [Int16](repeating: 0, count: 48_000)
        let gate = Self.cuts(tone + silence, energy: true)
        #expect(gate.count == 1 && gate[0].at > 3.0 && gate[0].at < 4.5 && gate[0].detected - 3.0 < 2.0, "energy gate cuts a normal-level burst in its pause (\(gate))")
        let hum = Self.cuts(silence + silence, energy: true)
        #expect(hum.isEmpty, "energy gate: silence alone never cuts")
        let forced = Self.cuts(Array([[Int16]](repeating: Array(tone[..<8_000]) + [Int16](repeating: 0, count: 4_000), count: 55).joined()), energy: true)
        #expect(forced.count == 1 && abs(forced[0].detected - 40) < 0.2, "40 s safety cut without a pause (\(forced))")
    }

    @Test(.enabled(if: modelTestsEnabled, "needs the Silero VAD model; set IONIAN_FLOW_MODEL_TESTS=1"))
    func vad() throws {
        // VAD: a real clip at RMS 0.001, then silence.
        let ready = DispatchSemaphore(value: 0)
        Task { await Segmenter.prepare(); ready.signal() }
        _ = ready.wait(timeout: .now() + 60)
        let clip = ["samples/de.wav", "../samples/de.wav", "../../samples/de.wav"]
            .lazy.compactMap { SegmenterReplay.wavData($0) }.first
        try #require(Segmenter.shared != nil, "VAD model could not be loaded")
        let samples = try #require(clip, "samples/de.wav missing")
        let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot() / 32768
        let quiet = samples.map { Int16((Double($0) * 0.001 / rms).rounded()) }
        let end = Double(quiet.count) / 16_000
        let v = Self.cuts(quiet + [Int16](repeating: 0, count: 80_000), energy: false)
        #expect(v.count == 1 && v[0].detected - end < 1.5 && v[0].detected - end > 0, "VAD cuts RMS-0.001 speech within 1.5 s of its end (\(v), end \(end))")
        let energyDeaf = Self.cuts(quiet + [Int16](repeating: 0, count: 80_000), energy: true)
        #expect(energyDeaf.isEmpty, "(the energy gate does not see it)")
        // Normal level, two clips apart: two cuts.
        let loud = samples + [Int16](repeating: 0, count: 24_000) + samples + [Int16](repeating: 0, count: 80_000)
        let two = Self.cuts(loud, energy: false)
        #expect(two.count == 2, "VAD: two utterances 1.5 s apart are two segments (\(two))")
    }
}
}
