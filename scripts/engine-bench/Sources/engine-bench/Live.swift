import AVFoundation
import FluidAudio
import Foundation

private enum LiveEvent { case audio([Float]), enter, quit }

/// Microphone to live partials on one terminal line. Enter ends the utterance (prints the final, with the
/// time from Enter to the final text) and starts the next; Ctrl-C ends the last one and quits.
/// Try --chunk 560 and --chunk 1120 and judge how late the words appear. The first run asks for
/// microphone permission for the terminal app; if it was denied, enable it in System Settings, Privacy.
func runLive(_ args: Args) async throws {
    let chunk = args.int("chunk", 1120)
    let language = args.str("language", "auto")
    let manager = try await loadManager(chunk: chunk, ship: args.str("ship", "latin"))
    await manager.setLanguage(language == "auto" ? "auto" : locale(language))
    _ = try await manager.process(samples: [Float](repeating: 0, count: 16000))
    _ = try await manager.finish()
    await manager.reset()

    var continuation: AsyncStream<LiveEvent>.Continuation!
    let events = AsyncStream<LiveEvent> { continuation = $0 }
    let cont = continuation!

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { cont.yield(.quit) }
    sigint.resume()
    Thread.detachNewThread {
        while readLine() != nil { cont.yield(.enter) }
        cont.yield(.quit)
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { fail("no microphone input (permission denied?)") }
    let mic = AudioConverter()
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        if let s = try? mic.resampleBuffer(buffer) { cont.yield(.audio(s)) }
    }
    try engine.start()
    say("Speak. Enter = finish utterance, Ctrl-C = quit. (\(chunk) ms chunks, language \(language))")

    func draw(_ text: String) {
        let t = text.count > 110 ? "…" + text.suffix(109) : text
        print("\r\u{1B}[2K\(t)", terminator: "")
        fflush(stdout)
    }
    var speaking = false
    for await event in events {
        switch event {
        case .audio(let samples):
            _ = try await manager.process(samples: samples)
            let partial = await manager.getPartialTranscript()
            if !partial.isEmpty { speaking = true }
            draw(partial)
        case .enter, .quit:
            let t = Date()
            let (text, _) = try await manager.finishWithTokenTimings()
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            let lang = await manager.lastDecodeStats().detectedLanguage ?? "-"
            await manager.reset()
            if speaking || !text.isEmpty {
                print("\r\u{1B}[2KFINAL (\(ms) ms after Enter, \(lang)): \(text)")
            } else { print("\r\u{1B}[2K(nothing heard)") }
            speaking = false
            if case .quit = event {
                engine.stop()
                return
            }
        }
    }
}
