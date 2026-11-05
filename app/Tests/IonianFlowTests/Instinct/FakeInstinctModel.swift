import Foundation
@testable import IonianFlow

struct FakeModelError: Error {}

/// Shared event list so tests can check the order of checkpoints and model calls.
final class EventLog { var events: [String] = [] }

/// A model that returns fixed items and verdicts, records what it was asked, and can be told to throw.
final class FakeInstinctModel: InstinctModel {
    var items: ([InstinctSource]) -> [InstinctItem] = { _ in [] }
    var verdict: InstinctVerdict = .new
    var extractFailures = 0          // the next n extract calls throw
    var judgeThrows = false
    var verification: (InstinctItem) -> InstinctVerification = { _ in InstinctVerification(holds: true, belongsToProject: true) }
    var verifyThrows = false
    private(set) var verifyCalls: [(item: InstinctItem, project: InstinctProjectHint?)] = []
    var log = EventLog()
    private(set) var extractCalls: [[InstinctSource]] = []
    private(set) var judgeCalls: [(item: InstinctItem, lines: [String])] = []

    func extract(_ sources: [InstinctSource], projects: [InstinctProjectHint]) async throws -> [InstinctItem] {
        log.events.append("extract")
        extractCalls.append(sources)
        if extractFailures > 0 { extractFailures -= 1; throw FakeModelError() }
        return items(sources)
    }

    func judge(_ item: InstinctItem, against lines: [String]) async throws -> InstinctVerdict {
        log.events.append("judge")
        judgeCalls.append((item, lines))
        if judgeThrows { throw FakeModelError() }
        return verdict
    }

    func verify(_ item: InstinctItem, speaker: InstinctSpeaker?, project: InstinctProjectHint?) async throws -> InstinctVerification {
        log.events.append("verify")
        verifyCalls.append((item, project))
        if verifyThrows { throw FakeModelError() }
        return verification(item)
    }
}
