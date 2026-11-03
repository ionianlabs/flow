import Foundation

// Unit B (live). NativeEngine: the SpeechEngine implementation. Owns sessions (SessionID counters per channel),
// event delivery on main, capabilities (.polish/.summary when ModelHub.gemmaAvailable), dictation sessions
// (buffer PCM, call an UtteranceFinalizer on end()), and forwarding polish/summarize to Polisher/Summarizer.
// Streaming itself lives in NativeLive.swift. Replace the fatalErrors; keep the type name and init.

final class NativeEngine: SpeechEngine {
    var onEvent: (EngineEvent) -> Void = { _ in }
    var isReady: Bool { fatalError("Unit B") }
    var capabilities: EngineCapabilities { fatalError("Unit B") }

    /// `finalizer` is Unit C's ParakeetFinalizer in the app; tests may pass a fake.
    init(hub: ModelHub = .shared, finalizer: UtteranceFinalizer? = nil) {}

    func start() { fatalError("Unit B") }
    func stop() { fatalError("Unit B") }
    func beginSession(_ o: SessionOptions) -> SessionID { fatalError("Unit B") }
    func push(_ s: SessionID, pcm: Data) { fatalError("Unit B") }
    func cut(_ s: SessionID, at sample: Int) { fatalError("Unit B") }
    func end(_ s: SessionID) { fatalError("Unit B") }
    func cancel(_ s: SessionID) { fatalError("Unit B") }
    func reloadVocabulary() { fatalError("Unit B") }
    func polish(id: Int, text: String, before: String) { fatalError("Unit B") }
    func summarize(id: Int, transcript: String, tags: [String]) { fatalError("Unit B") }
}
