// swift-tools-version: 6.0
// Phase 0 spike of the native engine: FluidAudio's multilingual Nemotron streaming (Core ML) measured
// against the Python sidecar. See main.swift for the subcommands.
import PackageDescription

let package = Package(
    name: "engine-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2")],
    targets: [
        .executableTarget(
            name: "engine-bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
