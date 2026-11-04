// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IonianFlow",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet on the Neural Engine for transcription mode's final text (FinalPass.swift).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
        // Cleanup model (Gemma) in-process; pins match coexist-bench. Update deliberately.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "IonianFlow",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/IonianFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Model-free checks run by default; the ones that need downloaded models are gated behind
        // IONIAN_FLOW_MODEL_TESTS=1 (see Tests/IonianFlowTests/Support.swift).
        .testTarget(
            name: "IonianFlowTests",
            dependencies: ["IonianFlow"],
            path: "Tests/IonianFlowTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
