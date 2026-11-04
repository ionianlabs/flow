import Foundation

/// Segmenter tests: the energy gate on normal-level tone bursts (no model needed), and the VAD on a real
/// clip from samples/ turned down to RMS ~0.001, where the energy gate is deaf. The VAD cases skip cleanly
/// when the model cannot be loaded or the clip is missing.
extension Segmenter {
    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ what: String) { print(c ? "ok   segmenter: \(what)" : "FAIL segmenter: \(what)"); ok = ok && c }

        // Energy gate: 3 s of a 0.1-level tone, then 3 s of silence -> a cut in the middle of the pause.
        let tone = (0..<48_000).map { Int16(0.1 * 32767 * sin(Double($0) * 2 * .pi * 220 / 16_000)) }
        let silence = [Int16](repeating: 0, count: 48_000)
        let gate = cuts(tone + silence, energy: true)
        check(gate.count == 1 && gate[0].at > 3.0 && gate[0].at < 4.5 && gate[0].detected - 3.0 < 2.0, "energy gate cuts a normal-level burst in its pause (\(gate))")
        let hum = cuts(silence + silence, energy: true)
        check(hum.isEmpty, "energy gate: silence alone never cuts")
        let forced = cuts(Array([[Int16]](repeating: Array(tone[..<8_000]) + [Int16](repeating: 0, count: 4_000), count: 55).joined()), energy: true)
        check(forced.count == 1 && abs(forced[0].detected - 40) < 0.2, "40 s safety cut without a pause (\(forced))")

        // VAD: a real clip at RMS 0.001, then silence.
        let ready = DispatchSemaphore(value: 0)
        Task { await Segmenter.prepare(); ready.signal() }
        _ = ready.wait(timeout: .now() + 60)
        let clip = ["samples/de.wav", "../samples/de.wav", "../../samples/de.wav"]
            .lazy.compactMap { SegmenterReplay.wavData($0) }.first
        guard Segmenter.shared != nil, let clip else {
            print("skip segmenter: VAD cases (model or samples/de.wav missing)")
            return ok
        }
        let rms = (clip.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(clip.count)).squareRoot() / 32768
        let quiet = clip.map { Int16((Double($0) * 0.001 / rms).rounded()) }
        let end = Double(quiet.count) / 16_000
        let v = cuts(quiet + [Int16](repeating: 0, count: 80_000), energy: false)
        check(v.count == 1 && v[0].detected - end < 1.5 && v[0].detected - end > 0, "VAD cuts RMS-0.001 speech within 1.5 s of its end (\(v), end \(end))")
        let energyDeaf = cuts(quiet + [Int16](repeating: 0, count: 80_000), energy: true)
        check(energyDeaf.isEmpty, "(the energy gate does not see it)")
        // Normal level, two clips apart: two cuts.
        let loud = clip + [Int16](repeating: 0, count: 24_000) + clip + [Int16](repeating: 0, count: 80_000)
        let two = cuts(loud, energy: false)
        check(two.count == 2, "VAD: two utterances 1.5 s apart are two segments (\(two))")
        return ok
    }

    private static func cuts(_ pcm: [Int16], energy: Bool) -> [SegmenterReplay.Cut] {
        SegmenterReplay.run(pcm, energy: energy, settings: Settings())
    }
}
