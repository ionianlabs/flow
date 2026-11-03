import MLXLMCommon

/// The one prefill rule for every Gemma call (Polisher, Summarizer, vault sweep).
/// Handed the whole prompt, the decode iterator computes lm_head logits for every prompt position (about 2x
/// slower), so all but the last tokens are prefilled in one step without logits. n-1 flips a near-tie case
/// against mlx-lm's output (a "Uhr" in the polish bench); n-2 matches mlx-lm on all 16 bench cases at the same speed.
enum GemmaPrefill {
    static let holdBack = 2

    static func stepSize(promptTokens n: Int) -> Int { max(1, n - holdBack) }

    /// Greedy decoding with the prefill rule applied.
    static func parameters(maxTokens: Int, promptTokens n: Int) -> GenerateParameters {
        var p = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        p.prefill.stepSize = stepSize(promptTokens: n)
        return p
    }
}
