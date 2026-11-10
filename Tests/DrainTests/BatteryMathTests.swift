import Foundation
import Testing
@testable import Drain

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

struct App: WattsRanked {
    let id: String
    let watts: Double
}

@Suite struct RuntimeEstimateTests {
    let est = RuntimeEstimate(hasBattery: true, remainingWh: 50)

    @Test func nilWithoutBatteryChargeOrDraw() {
        #expect(RuntimeEstimate(hasBattery: false, remainingWh: 50).minutesLeft(at: 10) == nil)
        #expect(RuntimeEstimate(hasBattery: true, remainingWh: 0).minutesLeft(at: 10) == nil)
        #expect(est.minutesLeft(at: 0.5) == nil)
        #expect(est.minutesLeft(at: 0) == nil)
        #expect(est.minutesLeft(at: -3) == nil)
        #expect(est.minutesLeft(at: 0.51) != nil)
    }

    @Test func proportionalAndInverse() throws {
        #expect(close(try #require(est.minutesLeft(at: 10)), 300))
        let doubled = RuntimeEstimate(hasBattery: true, remainingWh: 100)
        #expect(close(try #require(doubled.minutesLeft(at: 10)), 600))
        #expect(close(try #require(est.minutesLeft(at: 20)), 150))
    }

    @Test func scaledByCalibration() throws {
        let c = RuntimeEstimate(hasBattery: true, remainingWh: 50, calibration: 1.5)
        #expect(close(try #require(c.minutesLeft(at: 10)), 450))
    }

    @Test func gainZeroWithoutEstimate() {
        #expect(RuntimeEstimate(hasBattery: false, remainingWh: 50).gain(removing: 5, from: 10) == 0)
        #expect(RuntimeEstimate(hasBattery: true, remainingWh: 0).gain(removing: 5, from: 10) == 0)
        #expect(est.gain(removing: 5, from: 0.4) == 0)
    }

    @Test func gainNeverNegative() {
        #expect(est.gain(removing: 0, from: 10) == 0)
        #expect(est.gain(removing: -5, from: 10) == 0)
        #expect(est.gain(removing: 3, from: 10) > 0)
    }

    @Test func gainMatchesMinutesLeftDifference() throws {
        let c = RuntimeEstimate(hasBattery: true, remainingWh: 42, calibration: 1.2)
        let before = try #require(c.minutesLeft(at: 12))
        let after = try #require(c.minutesLeft(at: 9))
        #expect(close(c.gain(removing: 3, from: 12), after - before))
    }

    @Test func floorCapsDominantApp() throws {
        // total 10 W: floor is 2.5 W, so removing 9.9 W is the same as removing 7.5 W.
        #expect(close(est.gain(removing: 9.9, from: 10), est.gain(removing: 7.5, from: 10)))
        #expect(close(est.gain(removing: 100, from: 10), est.gain(removing: 7.5, from: 10)))
        let expected = try #require(est.minutesLeft(at: 2.5)) - (try #require(est.minutesLeft(at: 10)))
        #expect(close(est.gain(removing: 10, from: 10), expected))
        // low draw: the 0.6 W floor wins over a quarter (1.2 W total -> floor 0.6)
        let lowExpected = try #require(est.minutesLeft(at: 0.6)) - (try #require(est.minutesLeft(at: 1.2)))
        #expect(close(est.gain(removing: 5, from: 1.2), lowExpected))
        // quarter of 2 W is 0.5 < 0.6, so 0.6 is the floor
        let e2 = try #require(est.minutesLeft(at: 0.6)) - (try #require(est.minutesLeft(at: 2)))
        #expect(close(est.gain(removing: 2, from: 2), e2))
    }

    @Test func gainMonotonicInWatts() {
        var last = 0.0
        for i in 0...40 {
            let g = est.gain(removing: Double(i) * 0.5, from: 15)
            #expect(g >= last)
            last = g
        }
    }
}

@Suite struct CalibrationTests {
    @Test func reproducesNativeEstimate() throws {
        let k = try #require(BatteryMath.calibration(native: 300, remainingWh: 50, watts: 10))
        #expect(close(k, 1.0))
        let native = 400.0
        let k2 = try #require(BatteryMath.calibration(native: native, remainingWh: 50, watts: 10))
        let est = RuntimeEstimate(hasBattery: true, remainingWh: 50, calibration: k2)
        #expect(close(try #require(est.minutesLeft(at: 10)), native))
    }

    @Test func clamps() {
        #expect(BatteryMath.calibration(native: 1, remainingWh: 50, watts: 10) == 0.4)
        #expect(BatteryMath.calibration(native: 100000, remainingWh: 50, watts: 10) == 2.5)
    }

    @Test func nilForBadInputs() {
        #expect(BatteryMath.calibration(native: nil, remainingWh: 50, watts: 10) == nil)
        #expect(BatteryMath.calibration(native: 0, remainingWh: 50, watts: 10) == nil)
        #expect(BatteryMath.calibration(native: -5, remainingWh: 50, watts: 10) == nil)
        #expect(BatteryMath.calibration(native: 100, remainingWh: 0, watts: 10) == nil)
        #expect(BatteryMath.calibration(native: 100, remainingWh: -1, watts: 10) == nil)
        #expect(BatteryMath.calibration(native: 100, remainingWh: 50, watts: 0.5) == nil)
        #expect(BatteryMath.calibration(native: 100, remainingWh: 50, watts: 0) == nil)
    }
}

@Suite struct SmoothTests {
    @Test func takesNewWithoutHistory() {
        #expect(BatteryMath.smooth(nil, 7, dt: 5, tau: 10) == 7)
        #expect(BatteryMath.smooth(3, 7, dt: 0, tau: 10) == 7)
    }

    @Test func movesTowardWithoutOvershoot() {
        for (old, new) in [(0.0, 10.0), (10.0, 0.0), (5.0, 5.0)] {
            for dt in [0.1, 1, 10, 1000] {
                let r = BatteryMath.smooth(old, new, dt: dt, tau: 5)
                #expect(r >= min(old, new) && r <= max(old, new))
            }
        }
    }

    @Test func largerDtOrSmallerTauMovesFurther() {
        let a = BatteryMath.smooth(0, 10, dt: 1, tau: 5)
        let b = BatteryMath.smooth(0, 10, dt: 2, tau: 5)
        let c = BatteryMath.smooth(0, 10, dt: 1, tau: 2)
        #expect(a > 0 && b > a && c > a)
    }

    @Test func dtEqualTauIsAbout63Percent() {
        #expect(close(BatteryMath.smooth(0, 100, dt: 7, tau: 7), 63.2120558828557, 1e-6))
    }
}

@Suite struct ShouldMoveTests {
    @Test func threshold() {
        #expect(!BatteryMath.shouldMove(100, to: 102.9))
        #expect(BatteryMath.shouldMove(100, to: 103))
        #expect(BatteryMath.shouldMove(100, to: 97))
        // 3% of 200 is 6
        #expect(!BatteryMath.shouldMove(200, to: 205.9))
        #expect(BatteryMath.shouldMove(200, to: 206))
        #expect(BatteryMath.shouldMove(200, to: 194))
        #expect(!BatteryMath.shouldMove(50, to: 50))
        #expect(!BatteryMath.shouldMove(50, to: 52))
        #expect(BatteryMath.shouldMove(50, to: 53))
    }

    @Test func nilTransitions() {
        #expect(BatteryMath.shouldMove(nil, to: 10))
        #expect(BatteryMath.shouldMove(10, to: nil))
        #expect(!BatteryMath.shouldMove(nil, to: nil))
    }
}

@Suite struct StableOrderTests {
    private func ids(_ a: [App]) -> [String] { a.map(\.id) }

    @Test func noPreviousSortsBiggestFirst() {
        let r = BatteryMath.stableOrder([App(id: "a", watts: 1), App(id: "b", watts: 5), App(id: "c", watts: 3)], previous: [])
        #expect(ids(r) == ["b", "c", "a"])
    }

    @Test func keepsPreviousOrderWhenClose() {
        let apps = [App(id: "a", watts: 1.0), App(id: "b", watts: 1.3)]
        #expect(ids(BatteryMath.stableOrder(apps, previous: ["a", "b"])) == ["a", "b"])
        #expect(ids(BatteryMath.stableOrder(apps, previous: ["b", "a"])) == ["b", "a"])
    }

    @Test func swapsOnlyPastMargin() {
        let at = [App(id: "a", watts: 10), App(id: "b", watts: 14)]
        #expect(ids(BatteryMath.stableOrder(at, previous: ["a", "b"])) == ["a", "b"])
        let past = [App(id: "a", watts: 10), App(id: "b", watts: 14.1)]
        #expect(ids(BatteryMath.stableOrder(past, previous: ["a", "b"])) == ["b", "a"])
    }

    @Test func newcomersAfterKnownUnlessClearlyBigger() {
        let small = [App(id: "old", watts: 2), App(id: "new", watts: 2.5)]
        #expect(ids(BatteryMath.stableOrder(small, previous: ["old"])) == ["old", "new"])
        let big = [App(id: "old", watts: 2), App(id: "new", watts: 5)]
        #expect(ids(BatteryMath.stableOrder(big, previous: ["old"])) == ["new", "old"])
    }

    @Test func newcomersSortedAmongThemselves() {
        let apps = [App(id: "k", watts: 5), App(id: "x", watts: 1), App(id: "y", watts: 2)]
        #expect(ids(BatteryMath.stableOrder(apps, previous: ["k"])) == ["k", "y", "x"])
    }

    @Test func adversarialInputsReturnPermutation() {
        let cases: [[App]] = [
            [],
            [App(id: "a", watts: 0)],
            [App(id: "a", watts: 3), App(id: "b", watts: 3), App(id: "c", watts: 3)],
            [App(id: "a", watts: 0), App(id: "b", watts: 0), App(id: "c", watts: 0)],
            [App(id: "a", watts: 0), App(id: "b", watts: 0.001), App(id: "c", watts: 100)],
            (0..<30).map { App(id: "i\($0)", watts: pow(1.5, Double($0 % 7))) },
            (0..<30).map { App(id: "i\($0)", watts: Double($0)) }
        ]
        for c in cases {
            for prev in [[], c.map(\.id), c.map(\.id).reversed(), ["zzz"]] as [[String]] {
                let r = BatteryMath.stableOrder(c, previous: prev)
                #expect(ids(r).sorted() == ids(c).sorted())
            }
        }
    }

    @Test func zeroAfterZeroAndPositiveAfterZero() {
        // 0 * 1.4 = 0, so any positive neighbour overtakes a zero.
        let r = BatteryMath.stableOrder([App(id: "z", watts: 0), App(id: "p", watts: 0.01)], previous: ["z", "p"])
        #expect(ids(r) == ["p", "z"])
    }
}
