import Foundation
import Testing
@testable import IonianFlow

// Transcriber and dictation handling against the fake engine; no models, no audio devices.

extension IonianFlowTests {
@MainActor @Suite struct TranscriberWithFakeEngine {
    let dir: URL

    init() {
        Settings.registerDefaults()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ionian-fake-engine-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func pump(_ seconds: Double = 5, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// One two-channel meeting: returns the transcriber; the fake emits both channels' events.
    private func meeting(_ name: String, _ fake: EngineFake) -> Transcriber {
        let t = Transcriber(engine: fake, mic: AudioCapture())
        fake.onEvent = { _ = t.handleMain($0) }
        t.startForFiles(them: true, file: dir.appendingPathComponent(name + ".md"))
        let mic = SessionID(channel: .mic, n: 1), sys = SessionID(channel: .system, n: 1)
        fake.emit(.partial(mic, segment: 0, text: "so the plan is", lang: "en"))
        fake.emit(.partial(sys, segment: 0, text: "yes agreed", lang: "en"))
        fake.emit(.final(mic, segment: 0, text: "um so the plan is to ship on friday", lang: "en", start: 0.2, end: 3.1))
        fake.emit(.final(sys, segment: 0, text: "yes agreed", lang: "en", start: 3.4, end: 4.2))
        return t
    }

    private func texts(_ t: Transcriber, _ s: Speaker) -> [String] { t.model.segments.filter { $0.speaker == s }.map(\.text) }

    /// Cleanup present: both channels get sessions, finals are polished, a summary arrives.
    @Test func withCleanup() async {
        let fake = EngineFake()
        fake.polishReply = { $0 + " [polished]" }
        fake.summaryReply = TranscriptSummary(["description": "A short sync.", "points": ["Ship on Friday."]])
        let t = meeting("with-cleanup", fake)
        #expect(fake.begun.map(\.channel) == [.mic, .system] && fake.begun.allSatisfy { $0.kind == .transcription },
                "two transcription sessions on mic and system")
        #expect(texts(t, .you).first.map { $0.hasSuffix("[polished]") && !$0.lowercased().hasPrefix("um ") } == true,
                "You segment: filler removed, polished (\(texts(t, .you)))")
        #expect(texts(t, .them).first?.hasSuffix("[polished]") == true, "Them segment polished")
        #expect(t.model.segments.allSatisfy { $0.stage == .polished }, "stage polished")
        #expect(fake.polishCalls.first.map { $0.id == 0 && $0.text.isEmpty } == true, "polish preload at start")
        #expect(!t.model.cleanupOff, "cleanup shown as on")
        var finished = false
        t.onFinished = { finished = true }
        t.stop()
        await pump { finished && !t.model.summarizing }
        #expect(finished && fake.ended.count == 2, "stop ends both sessions, transcript finishes")
        #expect(fake.summaryCalls.count == 1 && t.model.summary?.points == ["Ship on Friday."], "summary requested and applied")
    }

    /// No cleanup model: finals stay final, nothing waits, no summary.
    @Test func noCleanup() async {
        let fake = EngineFake(capabilities: [])
        let t = meeting("no-cleanup", fake)
        #expect(t.model.segments.count == 2 && t.model.segments.allSatisfy { $0.stage == .final }, "segments stay final")
        #expect(fake.polishCalls.isEmpty, "no polish requests, no preload")
        #expect(t.model.cleanupOff, "UI flag says cleanup is off")
        var finished = false
        t.onFinished = { finished = true }
        t.stop()
        await pump(2) { finished }
        #expect(finished && fake.summaryCalls.isEmpty && !t.model.summarizing && t.model.summary == nil, "finishes at once, no summary")
    }

    /// Polish but no summary capability; a polish that never answers must not block forever (10 s guard is real
    /// time, so only the capability path is checked here).
    @Test func polishWithoutSummary() async {
        let fake = EngineFake(capabilities: [.polish])
        fake.polishReply = { $0 }
        let t = meeting("polish-only", fake)
        var finished = false
        t.onFinished = { finished = true }
        t.stop()
        await pump(2) { finished }
        #expect(finished && fake.summaryCalls.isEmpty && t.model.segments.allSatisfy { $0.stage == .polished }, "polish without summary")
    }

    /// A failed summary leaves the transcript alone.
    @Test func failedSummary() async {
        let fake = EngineFake()
        fake.polishReply = { $0 }
        let t = meeting("summary-fails", fake)
        var finished = false
        t.onFinished = { finished = true }
        t.stop()
        await pump { finished && !t.model.summarizing }
        #expect(fake.summaryCalls.count == 1 && t.model.summary == nil && !t.model.summarizing, "failed summary is dropped")
    }

    /// The spelling pass runs on transcription finals (an alias from a vocabulary file).
    @Test func spellingPass() {
        let vocab = dir.appendingPathComponent("vocabulary.md")
        let md = VocabularyFile.template.replacingOccurrences(of: "## Terms\n", with: "## Terms\n- pull request (heard as: pool request)\n")
        try? md.write(to: vocab, atomically: true, encoding: .utf8)
        #expect(SpellingPass.apply("please open a pool request", file: vocab) == "please open a pull request", "SpellingPass applies aliases")
    }

    /// Dictation: one .dictation session on the mic; partials and the final of that session only.
    @Test func dictation() {
        let fake = EngineFake(capabilities: [])
        var flow = DictationFlow()
        fake.finalOnEnd = { .final($0, segment: 0, text: "um this is a test", lang: "en", start: nil, end: nil) }
        let id = flow.begin(fake, language: "")
        fake.push(id, pcm: Data(count: 3_200))
        let other = SessionID(channel: .mic, n: 99)
        #expect(flow.update(for: .partial(other, segment: 0, text: "stale", lang: nil)) == nil, "other session's partial ignored")
        #expect(flow.update(for: .partial(id, segment: 0, text: "this is", lang: "en")) == .partial("This is", lang: "en"), "partial shown")
        var inserted: [String] = []
        fake.onEvent = { e in
            if case .final(let text, _)? = flow.update(for: e) { inserted.append(text) }
        }
        flow.end(fake)
        #expect(fake.begun.count == 1 && fake.begun[0].kind == .dictation && fake.begun[0].channel == .mic, "dictation session on mic")
        #expect(fake.pushed[id] == 3_200 && fake.ended == [id], "audio pushed, session ended")
        #expect(inserted == ["This is a test"], "final cleaned for insertion (\(inserted))")
        flow.cancel(fake)
        #expect(fake.cancelled == [id] && flow.session == nil, "cancel drops the session")
        #expect(flow.update(for: .final(id, segment: 0, text: "late", lang: nil, start: nil, end: nil)) == nil, "late final after cancel ignored")
    }
}
}
