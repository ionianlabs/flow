import Foundation
import Testing
@testable import IonianFlow

// F3.13 to F3.14: the stage's timing, as a pure function of time.
@Suite struct AwareStageTests {
    typealias S = AwareStage
    static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func offIsTheTeaser() {
        #expect(S.mode(on: false, enableStartedAt: nil, now: Self.t0) == .teaser)
        #expect(S.mode(on: false, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(0.5)) == .teaser)
    }

    // The enable moment plays once, starts only from the switch, and lasts 1.5 seconds.
    @Test func enableMomentPlaysOnceFromTheSwitch() {
        #expect(S.mode(on: true, enableStartedAt: nil, now: Self.t0) == .on)   // opening the page or launching
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0) == .enabling)
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(1.49)) == .enabling)
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(1.5)) == .on)
        #expect(S.mode(on: true, enableStartedAt: Self.t0, now: Self.t0.addingTimeInterval(60)) == .on)
        #expect(S.enableDuration == 1.5)
    }

    // The teaser: no loop. The lines rise once, one after the other, in about 3.5 s, then it rests.
    @Test func teaserPlaysOnceThenRests() {
        func f(_ t: Double) -> S.Frame { S.frame(mode: .teaser, since: t, reduceMotion: false) }
        #expect(S.teaserDuration >= 3 && S.teaserDuration <= 4)
        #expect(f(0).settle == [0, 0, 0] && f(0.2).settle == [0, 0, 0])
        let mid = f(1.8).settle
        #expect(mid[0] > 0.5 && mid[0] > mid[1] && mid[1] > mid[2])
        #expect(f(S.teaserDuration - 0.01).settle.allSatisfy { $0 > 0.99 })
        #expect(f(S.teaserDuration) == S.still(mode: .teaser))
        // After it ends it never changes again: no loop.
        for t in [4.0, 10, 16, 17, 100, 5000] { #expect(f(t) == S.still(mode: .teaser)) }
        // The stream stays calm: lower contrast than before, and quieter as the lines settle.
        #expect(f(0).streamOpacity <= 0.6 && f(S.teaserDuration - 0.01).streamOpacity < f(0).streamOpacity)
        #expect(f(0).clock < S.restClock && abs(f(S.teaserDuration - 0.001).clock - S.restClock) < 0.01)   // drift ends at rest
    }

    // The enable moment starts from the resting teaser and ends on the on frame: nothing jumps, nothing travels.
    @Test func enablingLetsTheLinesGoAndNothingTravels() {
        func f(_ since: Double) -> S.Frame { S.frame(mode: .enabling, since: since, reduceMotion: false) }
        #expect(f(0) == S.still(mode: .teaser))
        #expect(f(0.3).lineOpacity == 1)
        #expect(f(1.0).lineOpacity > 0 && f(1.0).lineOpacity < 1)
        let end = f(S.enableDuration - 0.001), on = S.still(mode: .on)
        #expect(end.lineOpacity < 0.01 && abs(end.amplitude - on.amplitude) < 0.01 && abs(end.streamOpacity - on.streamOpacity) < 0.01)
        #expect(f(S.enableDuration) == on)
        for t in stride(from: 0.0, to: 1.5, by: 0.25) { #expect(f(t).clock == S.restClock) }   // the wave does not drift
        #expect(on.streamOpacity < 0.4)
    }

    // On: fully still. Only a running sweep moves the wave, gently, and it shows no progress.
    @Test func onIsStillAndOnlyASweepMovesIt() {
        for t in [0.0, 3, 100] { #expect(S.frame(mode: .on, since: t, reduceMotion: false) == S.still(mode: .on)) }
        let start = S.frame(mode: .on, since: 0, reduceMotion: false, sweeping: true)
        #expect(start == S.still(mode: .on))   // no jump when a sweep begins
        let a = S.frame(mode: .on, since: 5, reduceMotion: false, sweeping: true)
        let b = S.frame(mode: .on, since: 6, reduceMotion: false, sweeping: true)
        #expect(a.clock != b.clock)
        #expect(a.amplitude > S.onAmplitude && a.amplitude < 0.5)
        #expect(a.settle == [0, 0, 0] && a.lineOpacity == 0)
    }

    // No timeline at rest: it animates only while something moves.
    @Test func animatesOnlyWhileSomethingMoves() {
        #expect(S.animates(mode: .teaser, since: 0, sweeping: false))
        #expect(S.animates(mode: .teaser, since: 3.49, sweeping: false))
        #expect(!S.animates(mode: .teaser, since: S.teaserDuration, sweeping: false))
        #expect(S.animates(mode: .enabling, since: 1.4, sweeping: false))
        #expect(!S.animates(mode: .enabling, since: 1.5, sweeping: false))
        #expect(!S.animates(mode: .on, since: 10, sweeping: false))
        #expect(S.animates(mode: .on, since: 10, sweeping: true))
    }

    // The teaser plays at most once per launch.
    @Test func teaserIsClaimedOncePerLaunch() {
        let before = AwareStageLaunch.played
        AwareStageLaunch.played = false
        #expect(AwareStageLaunch.claim())
        #expect(!AwareStageLaunch.claim() && !AwareStageLaunch.claim())
        AwareStageLaunch.played = before
    }

    // Reduce Motion: one composed still frame, whatever the time.
    @Test func reduceMotionSelectsTheStill() {
        for t in [0.0, 1.3, 9.9, 100] {
            #expect(S.frame(mode: .teaser, since: t, reduceMotion: true) == S.still(mode: .teaser))
            #expect(S.frame(mode: .enabling, since: t, reduceMotion: true) == S.still(mode: .on))
            #expect(S.frame(mode: .on, since: t, reduceMotion: true, sweeping: true) == S.still(mode: .on))
        }
        #expect(S.still(mode: .teaser).settle == [1, 1, 1])
    }

    // Cost: about 3 ms a frame, and frames only while something moves.
    @Test func frameRatesKeepTheCostLow() {
        #expect(S.refreshInterval(mode: .on, sweeping: true) >= 1.0 / 12 - 0.0001)
        #expect(S.refreshInterval(mode: .teaser, sweeping: false) >= 1.0 / 20 - 0.0001)
        #expect(S.refreshInterval(mode: .enabling, sweeping: false) <= 1.0 / 30 + 0.0001)
    }

    @Test func sampleTextIsInventedAndCalm() {
        #expect(S.fragments.map(\.tag) == ["To-do", "Decision", "Fact"])
        for t in S.fragments.map(\.text) + S.streamRows {
            #expect(!t.contains("!") && !t.contains("\u{2014}") && !t.contains("\u{2013}"))
        }
    }
}
