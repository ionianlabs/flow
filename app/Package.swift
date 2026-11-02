// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IonianFlow",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet on the Neural Engine for transcription mode's final text (FinalPass.swift).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .executableTarget(
            name: "IonianFlow",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/IonianFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
