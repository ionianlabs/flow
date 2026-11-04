import Foundation

// Unit 0 (skeleton). The one boundary between the app (Transcriber, main.swift) and a speech engine.
// NativeEngine (Unit B) is the only implementation. Types follow flow-phase1-design.md with these deviations:
//  - Channel/SessionID/SessionKind/SessionOptions/EngineEvent/EngineError are Sendable (events cross threads
//    before they are hopped to main).
//  - EngineCapabilities got its rawValue and the two members written out (the spec left them as "...").
//  - TranscriptSummary is the existing type in TranscriptSummary.swift (its init?([String: Any]) is a
//    Python-protocol leftover that Unit F may extend with a memberwise init; the type itself is unchanged).
//  - SessionOptions got an init with defaults, so call sites stay short.

enum Channel: Sendable, Hashable { case mic, system }

/// dictation: whole-utterance final (Parakeet via UtteranceFinalizer) on end(). transcription: live finals only.
enum SessionKind: Sendable, Hashable { case dictation, transcription }

struct SessionID: Hashable, Sendable {
    let channel: Channel
    let n: Int
}

struct SessionOptions: Sendable {
    /// "" = auto
    var language: String
    var channel: Channel
    var kind: SessionKind
    init(language: String = "", channel: Channel = .mic, kind: SessionKind = .transcription) {
        self.language = language; self.channel = channel; self.kind = kind
    }
}

/// polish/summary need the cleanup model (Gemma) to be downloaded.
struct EngineCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let polish = EngineCapabilities(rawValue: 1 << 0)
    static let summary = EngineCapabilities(rawValue: 1 << 1)
}

enum EngineError: Error, Sendable {
    case notReady
    case modelMissing(String)
    case failed(String)
}

enum EngineEvent: Sendable {
    case ready
    case partial(SessionID, segment: Int, text: String, lang: String?)
    case final(SessionID, segment: Int, text: String, lang: String?, start: Double?, end: Double?)
    case polished(id: Int, text: String)
    case summary(id: Int, TranscriptSummary?)
    case error(EngineError)
}

protocol SpeechEngine: AnyObject {
    /// Always delivered on main.
    var onEvent: (EngineEvent) -> Void { get set }
    var isReady: Bool { get }
    var capabilities: EngineCapabilities { get }
    func start()
    func stop()
    /// Audio-thread safe.
    func beginSession(_ o: SessionOptions) -> SessionID
    /// 16 kHz Int16 mono.
    func push(_ s: SessionID, pcm: Data)
    func cut(_ s: SessionID, at sample: Int)
    func end(_ s: SessionID)
    func cancel(_ s: SessionID)
    func reloadVocabulary()
    /// id 0 + "" = preload.
    func polish(id: Int, text: String, before: String)
    func summarize(id: Int, transcript: String, tags: [String])
}
