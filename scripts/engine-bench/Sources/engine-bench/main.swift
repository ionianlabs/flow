// engine-bench: Phase 0 spike of the native engine (FluidAudio multilingual Nemotron streaming).
//
//   wer WORKDIR --chunk 560|1120 [--language pinned|de|en|auto] [--sets fleurs,voxpopuli] [--ship latin|multilingual]
//   latency [--chunk 560] [--clips 10] [--out FILE]
//   live [--chunk 560|1120] [--language auto|de|en]
//   vocab DIR [--chunk 560]
//   mixed DIR [--chunk 560]
//
// swift run -c release engine-bench <subcommand> ...
import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    fail("usage: engine-bench wer|latency|live|vocab|mixed ... (see main.swift)")
}
let args = Args(Array(argv.dropFirst()))
switch cmd {
case "wer": try await runWer(args)
case "latency": try await runLatency(args)
case "live": try await runLive(args)
case "vocab": try await runVocab(args)
case "mixed": try await runMixed(args)
default: fail("unknown subcommand \(cmd)")
}
