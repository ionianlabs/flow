// llm-bench: runs the cleanup model through mlx-swift-lm, driven by JSON lines on stdin.
//
//   llm-bench <model dir> [--serial]
//
// stdin, one JSON object per line:
//   {"messages":[{"role":"system","content":"..."},{"role":"user","content":"..."}],
//    "max_tokens":60, "one_line":true}                  -> {"text":"...","ms":123,"tokens":17}
//   {"cmd":"stats"}                                      -> {"load_s":..,"rss_mb":..,"peak_rss_mb":..,"mlx_active_mb":..,"mlx_peak_mb":..}
// Generation is greedy (temperature 0), thinking off: exactly what asr/polish.py asks mlx-lm for.
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

setvbuf(stdout, nil, _IOLBF, 0)

func rssMB(peak: Bool) -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard r == KERN_SUCCESS else { return -1 }
    if peak {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_maxrss) / 1_048_576  // bytes on macOS
    }
    return Double(info.resident_size) / 1_048_576
}

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: llm-bench <model dir>\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)

let t0 = Date()
let container = try await LLMModelFactory.shared.loadContainer(
    from: dir, using: #huggingFaceTokenizerLoader())
// First eval pulls weights onto the GPU; Python's load() does the same lazily on the first request.
let loadSeconds = Date().timeIntervalSince(t0)
FileHandle.standardError.write(Data("loaded in \(String(format: "%.2f", loadSeconds)) s\n".utf8))

func visible(_ s: String) -> String {
    let thinkRe = try! Regex("<think>.*?</think>").dotMatchesNewlines()
    return String(s.replacing(thinkRe, with: "").drop(while: { $0.isWhitespace || $0.isNewline }))
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
        let req = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    if req["cmd"] as? String == "stats" {
        emit([
            "load_s": loadSeconds, "rss_mb": rssMB(peak: false), "peak_rss_mb": rssMB(peak: true),
            "mlx_active_mb": Double(Memory.activeMemory) / 1_048_576,
            "mlx_peak_mb": Double(Memory.peakMemory) / 1_048_576,
        ])
        continue
    }
    let msgs = (req["messages"] as? [[String: String]] ?? []).map { m -> Chat.Message in
        let content = m["content"] ?? ""
        switch m["role"] {
        case "system": return .system(content)
        case "assistant": return .assistant(content)
        default: return .user(content)
        }
    }
    let maxTokens = req["max_tokens"] as? Int ?? 300
    let oneLine = req["one_line"] as? Bool ?? false
    let t = Date()
    do {
        let input = try await container.prepare(
            input: UserInput(chat: msgs, additionalContext: ["enable_thinking": false]))
        var params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        if let step = ProcessInfo.processInfo.environment["LLM_BENCH_PREFILL_STEP"].flatMap(Int.init) {
            params.prefill.stepSize = step  // experiment: default chunking splits a 400-token prompt
        }
        let stream = try await container.generate(input: input, parameters: params)
        var out = ""
        var tokens = 0
        var diag: [String: Any] = [:]
        for await g in stream {
            if let i = g.info {  // only seen when generation ends by itself (no one_line break)
                diag = [
                    "prompt_tokens": i.promptTokenCount, "gen_tokens": i.generationTokenCount,
                    "prompt_ms": i.promptTime * 1000, "gen_ms": i.generateTime * 1000,
                ]
            }
            if let c = g.chunk {
                out += c
                tokens += 1
                let v = visible(out)
                if oneLine && !v.contains("<think>") && v.contains("\n") { break }
            }
        }
        emit(["text": out, "ms": Date().timeIntervalSince(t) * 1000, "chunks": tokens].merging(diag) { a, _ in a })
    } catch {
        emit(["error": "\(error)"])
    }
}
