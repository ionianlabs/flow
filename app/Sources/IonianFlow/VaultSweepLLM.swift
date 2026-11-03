import Foundation
import MLXLLM
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

// Unit F: how the summary and the vault sweep talk to Gemma, and how the sweep is paused.
// Generation is greedy with thinking off, as asr/polish.py asks mlx-lm for it, and follows the shared
// prefill rule (GemmaPrefill). Every call runs alone on
// ModelHub.serial, and checks a pause flag per token: a paused sweep gives the lane back at once, so
// dictation is never held up by more than one token.

struct ChatMsg { let role: String; let content: String }

protocol VaultLLM {
    func chat(_ messages: [ChatMsg], maxTokens: Int) async throws -> String
}

extension VaultLLM {
    func ask(_ system: String, _ user: String, maxTokens: Int) async throws -> String {
        try await chat([ChatMsg(role: "system", content: system), ChatMsg(role: "user", content: user)], maxTokens: maxTokens)
    }
}

/// Pause and resume for a running sweep (the SIGSTOP of the Python days). Cancellation wakes waiters.
final class SweepControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    func pause() { lock.lock(); paused = true; lock.unlock() }

    func resume() {
        lock.lock()
        paused = false
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume() }
    }

    /// Returns when not paused (or the task is cancelled).
    func waitWhilePaused() async {
        while isPaused && !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if paused && !Task.isCancelled { waiters.append(c); lock.unlock() } else { lock.unlock(); c.resume() }
                }
            } onCancel: { [self] in
                lock.lock(); let w = waiters; waiters = []; lock.unlock()
                w.forEach { $0.resume() }
            }
        }
    }
}

final class GemmaVaultLLM: VaultLLM {
    private let load: () async throws -> ModelContainer
    private let hub: ModelHub
    private let control: SweepControl?

    /// The app's Gemma (ModelHub); `control` pauses it between tokens.
    init(hub: ModelHub = .shared, control: SweepControl? = nil) {
        self.hub = hub
        self.control = control
        load = { try await hub.gemma() }
    }

    /// A model folder on disk (tests, before the hub has its loaders).
    init(directory: URL, hub: ModelHub = .shared, control: SweepControl? = nil) {
        self.hub = hub
        self.control = control
        load = { try await LLMModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader()) }
    }

    private var container: ModelContainer?

    func chat(_ messages: [ChatMsg], maxTokens: Int) async throws -> String {
        while true {
            try Task.checkCancellation()
            await control?.waitWhilePaused()
            try Task.checkCancellation()
            let c = try await container()
            let result: String? = try await hub.serial(.low, label: "llm") { try await self.generate(c, messages, maxTokens) }
            if let result { return result }  // nil: paused mid-answer; ask again after the resume
        }
    }

    private func container() async throws -> ModelContainer {
        if let c = container { return c }
        let c = try await load()
        container = c
        return c
    }

    private func generate(_ container: ModelContainer, _ messages: [ChatMsg], _ maxTokens: Int) async throws -> String? {
        let msgs = messages.map { m -> Chat.Message in
            switch m.role {
            case "system": return .system(m.content)
            case "assistant": return .assistant(m.content)
            default: return .user(m.content)
            }
        }
        let input = try await container.prepare(input: UserInput(chat: msgs, additionalContext: ["enable_thinking": false]))
        let params = GemmaPrefill.parameters(maxTokens: maxTokens, promptTokens: input.text.tokens.size)  // shared prefill rule
        let stream = try await container.generate(input: input, parameters: params)
        var out = ""
        for await g in stream {
            if Task.isCancelled { throw CancellationError() }
            if control?.isPaused == true { return nil }
            if let c = g.chunk { out += c }
        }
        return Self.think.sub(out, "").pyStrip
    }

    private static let think = SweepRe(#"<think>.*?</think>"#, .dotMatchesLineSeparators)
}
