import Foundation
@testable import IonianFlow

struct FakeModelError: Error {}

/// A model that returns fixed items and verdicts, records what it was asked, and can be told to throw.
final class FakeInstinctModel: InstinctModel {
    var items: ([InstinctSource]) -> [InstinctItem] = { _ in [] }
    var verdict: InstinctVerdict = .new
    var extractFailures = 0          // the next n extract calls throw
    var judgeThrows = false
    private(set) var extractCalls: [[InstinctSource]] = []
    private(set) var judgeCalls: [(item: InstinctItem, lines: [String])] = []

    func extract(_ sources: [InstinctSource], projects: [InstinctProjectHint]) async throws -> [InstinctItem] {
        extractCalls.append(sources)
        if extractFailures > 0 { extractFailures -= 1; throw FakeModelError() }
        return items(sources)
    }

    func judge(_ item: InstinctItem, against lines: [String]) async throws -> InstinctVerdict {
        judgeCalls.append((item, lines))
        if judgeThrows { throw FakeModelError() }
        return verdict
    }
}
