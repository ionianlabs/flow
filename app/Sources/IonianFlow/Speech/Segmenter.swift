import FluidAudio
import Foundation

/// Cuts a continuous stream into segments at pauses, so every finished segment can be shown as final and
/// polished right away. `feed` is called on the audio thread and never blocks (except in `lockstep` mode).
///
/// Speech is told from silence by Silero VAD (FluidAudio): quiet speech and cross-talk at -60 dB count as
/// speech, which an absolute energy gate never saw (segments then ran to the 40 s cut, finals lagged 14-26 s).
/// The model runs on a private serial queue over 4096-sample frames (256 ms); `feed` collects its
/// probabilities from the frames done so far, so a cut is decided at most one frame plus one inference late.
/// Without the model (not downloaded, failed to load) the old energy gate decides.
final class Segmenter: @unchecked Sendable {
    static let rate = 16_000
    /// Silero probability that starts / ends speech (hysteresis), and the pause that cuts a segment.
    struct Settings {
        var enter: Float = 0.5
        var exit: Float = 0.35
        var pause = 0.7          // seconds of silence that end a segment of at least `minSegment`
        var minSegment = 2.0
        var longSegment = 20.0   // after this long a pause of `longPause` is enough
        var longPause = 0.3
        var forced = 40.0
        var target: Float = 0.05    // frames are raised to this RMS before the model (it is level sensitive)
        var minRMS: Float = 0.0002  // quieter frames are digital silence / dither and are left alone
        var maxGain: Float = 100
    }

    /// Loaded VAD, shared by every segmenter; set by `prepare`.
    nonisolated(unsafe) static var shared: VadManager?
    static func prepare() async { if shared == nil { shared = await ModelHub.shared.vad() } }

    /// Cost of the model per frame, for the log and the replay (seconds, total and frame count).
    nonisolated(unsafe) static var cost = (seconds: 0.0, frames: 0, worst: 0.0)
    private static let costLock = NSLock()

    var settings = Settings()
    /// Tests and the replay: every `feed` waits for the model, so the result does not depend on timing.
    var lockstep = false
    /// Force the energy gate even if the model is loaded (replay: old vs. new).
    var energyOnly = false

    // Audio thread.
    private var total = 0              // samples fed
    private var segStart = 0           // absolute sample where the open segment began
    private var pending: [Float] = []  // not yet a whole frame
    private var floor: Float = 0.01    // energy gate
    private var silent = 0, samples = 0, heard = false

    // VAD state, touched under the lock (queue writes, audio thread reads).
    private let queue = DispatchQueue(label: "ionian.segmenter.vad", qos: .userInitiated)
    private let lock = NSLock()
    private var probs: [(end: Int, p: Float)] = []
    private var vadState = VadStreamState.initial()  // queue only
    private var frameEnd = 0                          // queue only
    private var inSpeech = false                      // audio thread: hysteresis over the probabilities
    private var lastSpeechEnd: Int?                   // absolute sample where speech last ended in this segment
    private var usingVAD = false
    private var seenEnd = 0                           // audio thread: end of the last frame the model finished

    static func rms(_ pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var sum: Float = 0
            for v in s { let f = Float(v) / 32768; sum += f * f }
            return sqrt(sum / Float(max(1, s.count)))
        }
    }

    /// Feeds one chunk; at a cut, how many samples before the chunk's end the segment ends: the
    /// middle of the pause.
    func feed(_ pcm: Data) -> Int? {
        let n = pcm.count / 2
        total += n
        if !energyOnly, let vad = Self.shared {
            if !usingVAD { usingVAD = true; startVAD(at: total - n) }
            return feedVAD(pcm, vad)
        }
        return feedEnergy(pcm)
    }

    // MARK: VAD

    /// Switch from the energy gate: the open segment stays, speech state starts fresh.
    private func startVAD(at sample: Int) {
        frameEnd = sample
        seenEnd = sample
        lastSpeechEnd = nil
        inSpeech = false
        pending = []
    }

    private func feedVAD(_ pcm: Data, _ vad: VadManager) -> Int? {
        pcm.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) { pending.append(Float(v) / 32768) }
        }
        let frame = VadManager.chunkSize
        while pending.count >= frame {
            var chunk = Array(pending[..<frame])
            let s = settings
            var energy: Float = 0
            for v in chunk { energy += v * v }
            let level = (energy / Float(frame)).squareRoot()
            if level >= s.minRMS, level < s.target {
                let g = min(s.maxGain, s.target / level)
                for i in chunk.indices { chunk[i] *= g }
            }
            pending.removeFirst(frame)
            let run = { [self] in
                let t0 = DispatchTime.now().uptimeNanoseconds
                let state = vadState
                var p: Float = 0
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var out: VadStreamResult?
                Task.detached {
                    out = try? await vad.processStreamingChunk(chunk, state: state)
                    sem.signal()
                }
                sem.wait()
                if let out { vadState = out.state; p = out.probability }
                frameEnd += frame
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                Self.costLock.lock(); Self.cost.seconds += dt; Self.cost.frames += 1; Self.cost.worst = max(Self.cost.worst, dt); Self.costLock.unlock()
                lock.lock(); probs.append((frameEnd, p)); lock.unlock()
            }
            if lockstep { queue.sync(execute: run) } else { queue.async(execute: run) }
        }
        lock.lock()
        let done = probs
        probs = []
        lock.unlock()
        for (end, p) in done {
            if inSpeech ? p >= settings.exit : p >= settings.enter {
                inSpeech = true
                lastSpeechEnd = end
            } else {
                inSpeech = false
            }
            seenEnd = end
        }
        let rate = Double(Self.rate)
        let seconds = Double(total - segStart) / rate
        if let last = lastSpeechEnd, last > segStart {
            // The decision uses the audio the model has seen: silence is counted up to the last frame done.
            let seen = max(seenEnd, last)
            let pause = Double(seen - last) / rate
            let cut = (seconds >= settings.minSegment && pause >= settings.pause)
                || (seconds >= settings.longSegment && pause >= settings.longPause)
            if cut {
                let at = last + (seen - last) / 2
                return finish(at: at)
            }
        }
        if seconds >= settings.forced { return finish(at: total) }
        return nil
    }

    private func finish(at sample: Int) -> Int {
        let back = max(0, total - sample)
        segStart = total - back
        lastSpeechEnd = nil
        return back
    }

    // MARK: Energy gate (fallback, the former rule)

    private func feedEnergy(_ pcm: Data) -> Int? {
        let rms = Self.rms(pcm), n = pcm.count / 2
        // Noise floor: follows quiet stretches down at once, creeps up slowly during speech.
        floor = rms < floor ? rms : floor + (rms - floor) * 0.005
        let speech = rms > max(0.006, floor * 3)
        samples += n
        silent = speech ? 0 : silent + n
        heard = heard || speech
        let seconds = Double(samples) / Double(Self.rate), pause = Double(silent) / Double(Self.rate)
        // Pauses only end a segment that has speech in it; silence just keeps streaming.
        let cut = heard && ((seconds >= 2 && pause >= 0.7) || (seconds >= 20 && pause >= 0.3))
        guard cut || seconds >= 40 else { return nil }
        let back = cut ? silent / 2 : 0
        samples = back
        silent = back
        heard = false
        segStart = total - back
        return back
    }
}
