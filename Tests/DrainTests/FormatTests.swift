import Testing
@testable import Drain

@Suite struct FormatTests {
    @Test func clock() {
        #expect(Format.clock(220) == "3:40")
        #expect(Format.clock(0) == "0:00")
        #expect(Format.clock(5) == "0:05")
        #expect(Format.clock(60) == "1:00")
        #expect(Format.clock(59.4) == "0:59")
        #expect(Format.clock(59.6) == "1:00")
        #expect(Format.clock(119.5) == "2:00")
        #expect(Format.clock(119.4) == "1:59")
    }

    @Test func cost() {
        #expect(Format.cost(70) == "−70m")
        #expect(Format.cost(1) == "−1m")
        #expect(Format.cost(1.4) == "−1m")
        #expect(Format.cost(0.5) == "−30s")
        #expect(Format.cost(0.0001) == "−1s")
        #expect(Format.cost(0) == "−1s")
    }

    @Test func gain() {
        #expect(Format.gain(70) == "+70 min")
        #expect(Format.gain(1) == "+1 min")
        #expect(Format.gain(0.5) == "+30 sec")
        #expect(Format.gain(0.0001) == "+1 sec")
    }

    @Test func neverRendersSixtySeconds() {
        for m in [0.99, 0.9917, 0.999, 0.9999, 0.99999] {
            #expect(Format.cost(m) != "−60s", "cost(\(m)) = \(Format.cost(m))")
            #expect(Format.gain(m) != "+60 sec", "gain(\(m)) = \(Format.gain(m))")
        }
    }

    @Test func watts() {
        #expect(Format.watts(0) == "<0.1 W")
        #expect(Format.watts(0.049) == "<0.1 W")
        #expect(Format.watts(0.05) == "0.1 W")
        #expect(Format.watts(2.14) == "2.1 W")
        #expect(Format.watts(9.94) == "9.9 W")
        #expect(Format.watts(10) == "10 W")
        #expect(Format.watts(23.4) == "23 W")
    }

    @Test func wattsJustBelowTenDoesNotRoundToTenPointZero() {
        #expect(Format.watts(9.96) != "10.0 W")
    }
}
