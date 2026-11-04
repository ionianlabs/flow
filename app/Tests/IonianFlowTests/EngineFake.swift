import Foundation
@testable import IonianFlow

/// A scripted SpeechEngine for model-free tests: it records every call, and the test (or the hooks) emit the
/// events a real engine would. Events are delivered synchronously on the calling thread (main in tests).
final class EngineFake: SpeechEngine {
    var onEvent: (EngineEvent) -> Void = { _ in }
    var isReady = true
    var capabilities: EngineCapabilities

    // Recorded calls.
    private(set) var begun: [SessionOptions] = []
    private(set) var pushed: [SessionID: Int] = [:]  // bytes per session
    private(set) var cuts: [(SessionID, Int)] = []
    private(set) var ended: [SessionID] = []
    private(set) var cancelled: [SessionID] = []
    private(set) var polishCalls: [(id: Int, text: String, before: String)] = []
    private(set) var summaryCalls: [(id: Int, transcript: String)] = []
    private var counters: [Channel: Int] = [:]

    // Scripts: what the fake answers by itself.
    var polishReply: ((String) -> String)?  // nil: never answers
    var summaryReply: TranscriptSummary?  // nil: answers "failed"
    var finalOnEnd: ((SessionID) -> EngineEvent?)?

    init(capabilities: EngineCapabilities = [.polish, .summary]) { self.capabilities = capabilities }

    func emit(_ e: EngineEvent) { onEvent(e) }

    func start() { emit(.ready) }
    func stop() { isReady = false }
    func beginSession(_ o: SessionOptions) -> SessionID {
        begun.append(o)
        counters[o.channel, default: 0] += 1
        return SessionID(channel: o.channel, n: counters[o.channel]!)
    }
    func push(_ s: SessionID, pcm: Data) { pushed[s, default: 0] += pcm.count }
    func cut(_ s: SessionID, at sample: Int) { cuts.append((s, sample)) }
    func end(_ s: SessionID) {
        ended.append(s)
        if let e = finalOnEnd?(s) { emit(e) }
    }
    func cancel(_ s: SessionID) { cancelled.append(s) }
    func reloadVocabulary() {}
    func polish(id: Int, text: String, before: String) {
        polishCalls.append((id, text, before))
        if id != 0, let reply = polishReply { emit(.polished(id: id, text: reply(text))) }
    }
    func summarize(id: Int, transcript: String, tags: [String]) {
        summaryCalls.append((id, transcript))
        emit(.summary(id: id, summaryReply))
    }
}
