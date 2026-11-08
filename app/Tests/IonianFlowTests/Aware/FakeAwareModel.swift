import Foundation
@testable import IonianFlow

struct FakeModelError: Error {}

/// Shared event list so tests can check the order of checkpoints and model calls.
final class EventLog { var events: [String] = [] }

/// A model that returns fixed items and verdicts, records what it was asked, and can be told to throw.
final class FakeAwareModel: AwareModel {
    var items: ([AwareSource]) -> [AwareItem] = { _ in [] }
    var verdict: AwareVerdict = .new
    var extractFailures = 0          // the next n extract calls throw
    var judgeThrows = false
    var verification: (AwareItem) -> AwareVerification = { _ in AwareVerification(holds: true, belongsToProject: true) }
    var verifyThrows = false
    private(set) var verifyCalls: [(item: AwareItem, project: AwareProjectHint?)] = []
    var log = EventLog()
    private(set) var extractCalls: [[AwareSource]] = []
    private(set) var judgeCalls: [(item: AwareItem, lines: [String])] = []

    func extract(_ sources: [AwareSource], projects: [AwareProjectHint]) async throws -> [AwareItem] {
        log.events.append("extract")
        extractCalls.append(sources)
        if extractFailures > 0 { extractFailures -= 1; throw FakeModelError() }
        return items(sources)
    }

    func judge(_ item: AwareItem, against lines: [String]) async throws -> AwareVerdict {
        log.events.append("judge")
        judgeCalls.append((item, lines))
        if judgeThrows { throw FakeModelError() }
        return verdict
    }

    func verify(_ item: AwareItem, speaker: AwareSpeaker?, project: AwareProjectHint?) async throws -> AwareVerification {
        log.events.append("verify")
        verifyCalls.append((item, project))
        if verifyThrows { throw FakeModelError() }
        return verification(item)
    }
}
