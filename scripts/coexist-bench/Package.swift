// swift-tools-version: 6.2
// Phase 0 coexistence test: every model of the native engine in ONE process for 30 minutes
// (two Nemotron streams, Parakeet Ultra + CTC vocabulary model, Gemma 4 E2B). See main.swift.
// Pins are exact on purpose (FluidAudio like engine-bench, MLX like llm-bench); update deliberately.
import PackageDescription

let package = Package(
    name: "coexist-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "coexist-bench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
