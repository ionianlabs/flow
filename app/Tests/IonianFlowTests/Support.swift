import Foundation
import Testing

/// Tests that load models (Silero VAD, Parakeet, Gemma) or touch the network are gated behind this flag:
///   IONIAN_FLOW_MODEL_TESTS=1 swift test --package-path app
/// Run them under the model lock (python3 native-bench/withlock.py ...) so they do not collide with other model jobs.
let modelTestsEnabled = ProcessInfo.processInfo.environment["IONIAN_FLOW_MODEL_TESTS"] == "1"

/// Every suite nests in here, so the tests run one at a time: several touch process-wide state
/// (environment variables, the URLProtocol stub, the main run loop, the shared model hub).
@Suite(.serialized) struct IonianFlowTests {}
