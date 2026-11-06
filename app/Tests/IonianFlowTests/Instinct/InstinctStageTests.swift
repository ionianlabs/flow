import Foundation
import Testing
@testable import IonianFlow

// F3.13 to F3.14: the stage's timing, as a pure function of time.
@Suite struct InstinctStageTests {
    typealias S = InstinctStage
    static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func offIsTheTeaser() {
        #expect(S.mode(on: false, enableStartedAt: nil, now: Self.t0) == .teaser)
        #expect(S.mode(on: false, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(0.5)) == .teaser)
    }

    // The enable moment plays once, starts only from the switch, and lasts 1.8 seconds.
    @Test func enableMomentPlaysOnceFromTheSwitch() {
        #expect(S.mode(on: true, enableStartedAt: nil, now: Self.t0) == .on)   // opening the page or launching
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0) == .enabling)
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(1.79)) == .enabling)
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(1.8)) == .on)
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(60)) == .on)
        #expect(S.enableDuration >= 1.5 && S.enableDuration <= 2)
    }

    @Test func teaserShowsNoLinesThenSettlesThemInOrderThenLetsGo() {
        func f(_ t: Double) -> S.Frame { S.frame(mode: .teaser, clock: t, reduceMotion: false) }
        #expect(f(1).settle == [0, 0, 0])
        let mid = f(4.2).settle
        #expect(mid[0] > 0.5 && mid[0] > mid[1] && mid[1] > mid[2])
        #expect(f(9).settle.allSatisfy { $0 > 0.99 })
        #expect(f(15.9).settle == [0, 0, 0] || f(15.9).settle.allSatisfy { $0 < 0.001 })
        // It loops.
        #expect(f(1) == S.frame(mode: .teaser, clock: 1 + S.teaserPeriod, reduceMotion: false).withClock(1))
        #expect(f(9).streamOpacity < f(1).streamOpacity)
    }

    @Test func enablingGathersSettlesThenResolvesIntoTheOnFrame() {
        func f(_ since: Double) -> S.Frame { S.frame(mode: .enabling, clock: 20, since: since, reduceMotion: false) }
        #expect(f(0).settle == [0, 0, 0])
        #expect(f(1.0).settle.allSatisfy { $0 > 0.5 } && f(1.1).lineOpacity > 0.9)
        #expect(f(1.15).settle.allSatisfy { $0 > 0.9 })
        // At the end it is the on frame, so nothing jumps when the mode changes.
        let end = f(S.enableDuration)
        let on = S.frame(mode: .on, clock: 20, reduceMotion: false)
        #expect(end.lineOpacity < 0.001 && abs(end.amplitude - on.amplitude) < 0.001 && abs(end.streamOpacity - on.streamOpacity) < 0.001)
        // It starts where the teaser stands at rest (stream fully there, lines not yet).
        #expect(f(0).streamOpacity == 1 && f(0).amplitude == 1)
    }

    @Test func onIsNearlyStillAndSweepingMovesAMoreNotFake() {
        let quiet = S.frame(mode: .on, clock: 5, reduceMotion: false)
        let busy = S.frame(mode: .on, clock: 5, reduceMotion: false, sweeping: true)
        #expect(quiet.amplitude < 0.5 && quiet.lineOpacity == 0)
        #expect(busy.amplitude > quiet.amplitude && busy.amplitude < 0.7)
        #expect(busy.settle == quiet.settle)   // no progress shown
    }

    // Reduce Motion: one composed still frame, whatever the time.
    @Test func reduceMotionSelectsTheStill() {
        for t in [0.0, 3.3, 9.9, 100] {
            #expect(S.frame(mode: .teaser, clock: t, reduceMotion: true) == S.still(mode: .teaser))
            #expect(S.frame(mode: .enabling, clock: t, since: t / 60, reduceMotion: true) == S.still(mode: .on))
            #expect(S.frame(mode: .on, clock: t, reduceMotion: true, sweeping: true) == S.still(mode: .on))
        }
        #expect(S.still(mode: .teaser).settle == [1, 1, 1])
    }

    // Cost: about 3 ms a frame, so the rates stay low; nothing loops faster than a calm 15 frames, except the 1.8 s moment.
    @Test func frameRatesKeepTheCostLow() {
        #expect(S.refreshInterval(mode: .on, sweeping: false) >= 1.0 / 12)
        #expect(S.refreshInterval(mode: .teaser, sweeping: false) >= 1.0 / 15 - 0.0001)
        #expect(S.refreshInterval(mode: .on, sweeping: true) < S.refreshInterval(mode: .on, sweeping: false))
        #expect(S.refreshInterval(mode: .enabling, sweeping: false) <= 1.0 / 30 + 0.0001)
    }

    @Test func sampleTextIsInventedAndCalm() {
        #expect(S.fragments.map(\.tag) == ["To-do", "Decision", "Fact"])
        for t in S.fragments.map(\.text) + S.streamRows {
            #expect(!t.contains("!") && !t.contains("\u{2014}") && !t.contains("\u{2013}"))
        }
    }
}

private extension InstinctStage.Frame {
    func withClock(_ c: Double) -> InstinctStage.Frame { var f = self; f.clock = c; return f }
}
