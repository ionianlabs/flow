import Foundation
import Testing
@testable import IonianFlow

extension IonianFlowTests {
@MainActor @Suite struct ModelSetupChecks {
    /// State machine: missing, downloading, installed; cancel and resume; error and retry; skip; already installed; remove.
    @Test func stateMachine() async {
        func check(_ ok: Bool, _ what: String) { #expect(ok, "model setup: \(what)") }
        func wait(_ what: String, _ cond: () -> Bool) async {
            let end = Date().addingTimeInterval(3)
            while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
            check(cond(), "timeout: \(what)")
        }

        // Fresh install: speech missing, Continue locked.
        let store = FakeModelStore()
        let m = ModelSetupModel(store: store)
        var changed: [ModelItem] = []
        var willRemove: [ModelItem] = []
        m.onChange = { changed.append($0) }
        m.onWillRemove = { willRemove.append($0) }
        check(m.phase(.speech) == .missing && !m.canContinue && !m.allInstalled, "starts missing")
        check(m.bytesText(.speech) == "2.4 GB" && m.bytesText(.cleanup) == "3.0 GB", "size text")
        check(ModelSetupModel.sizeText(350_000_000) == "350 MB", "size text MB")

        // missing -> downloading -> installed
        m.start(.speech)
        check(m.phase(.speech).isBusy, "downloading after start")
        await wait("progress") { m.phase(.speech) == .downloading(0.4) }
        store.hold = false
        await wait("speech installed") { m.phase(.speech) == .installed }
        check(m.canContinue && changed == [.speech], "continue unlocked, onChange(speech) once")
        m.start(.speech)
        check(m.phase(.speech) == .installed, "start on installed is a no-op")

        // cancel -> paused -> resume -> installed
        store.hold = true
        m.start(.cleanup)
        await wait("cleanup progress") { m.phase(.cleanup) == .downloading(0.4) }
        m.cancel(.cleanup)
        check(m.phase(.cleanup) == .paused(0.4) && store.cancelCalls == 1, "cancel pauses and tells the store")
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(m.phase(.cleanup) == .paused(0.4), "late cancelled error does not turn into a failure")
        m.start(.cleanup)
        check(m.phase(.cleanup) == .downloading(0.4), "resume continues from the paused point")
        store.hold = false
        await wait("cleanup installed") { m.phase(.cleanup) == .installed }
        check(changed == [.speech, .cleanup] && m.allInstalled, "cleanup installed")

        // remove cleanup
        m.remove(.cleanup)
        await wait("cleanup removed") { m.phase(.cleanup) == .missing }
        check(willRemove == [.cleanup] && store.removeCalls == 1 && changed.last == .cleanup, "remove unloads first and notifies")

        // error -> retry; skip cleanup
        let s2 = FakeModelStore()
        let e = ModelSetupModel(store: s2)
        s2.failNext(.speech)
        e.start(.speech)
        await wait("failed") { if case .failed = e.phase(.speech) { return true } else { return false } }
        check(!e.canContinue, "failure keeps Continue locked")
        s2.hold = false
        e.start(.speech)
        await wait("retry installed") { e.phase(.speech) == .installed }
        e.skipCleanup()
        check(e.cleanupSkipped && e.canContinue && e.phase(.cleanup) == .missing, "skip cleanup: continue allowed, cleanup stays off")
        s2.hold = true
        e.start(.cleanup)
        check(!e.cleanupSkipped, "starting the download clears the skip")
        e.skipCleanup()
        check(e.cleanupSkipped && !e.phase(.cleanup).isBusy, "skip during a download pauses it")

        // already installed: nothing to do
        let done = ModelSetupModel(store: FakeModelStore(installed: [.speech, .cleanup]))
        check(done.allInstalled && done.canContinue, "installed users skip the step")

        check(ModelSetupModel.message(for: ModelStoreError.disk("x")).contains("disk"), "error text")
    }
}
}
