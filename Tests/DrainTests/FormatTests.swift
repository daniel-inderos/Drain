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

    @Test func chargeLine() {
        func line(_ state: PowerState, _ time: Double?, _ watts: Double?, _ policy: ChargePolicy = ChargePolicy()) -> String? {
            Format.chargeLine(state, percent: 82, timeToFull: time, batteryWatts: watts, policy: policy)
        }
        #expect(line(.charging, 80, 38.4) == "Charging at 38 W · Full in 1:20")
        #expect(line(.charging, nil, 38.4) == "Charging at 38 W")
        #expect(line(.charging, 80, nil) == "Charging · Full in 1:20")
        // A trickle, or a reading that says "out" while macOS says charging, isn't a rate worth showing.
        #expect(line(.charging, nil, 0.4) == "Charging")
        #expect(line(.charging, nil, -5) == "Charging")
        #expect(line(.charged, nil, 0) == "Fully Charged")
        #expect(line(.onHold, nil, -21.4) == "Not Charging · Draining at 21 W")
        #expect(line(.onHold, nil, -1) == "Not Charging")
        #expect(line(.onHold, nil, nil) == "Not Charging")
        #expect(line(.battery, nil, -12) == nil)
        #expect(line(.noBattery, nil, nil) == nil)
    }

    @Test func chargeLineWithPolicy() {
        func line(_ state: PowerState, _ time: Double?, _ watts: Double?, _ policy: ChargePolicy) -> String? {
            Format.chargeLine(state, percent: 82, timeToFull: time, batteryWatts: watts, policy: policy)
        }
        let held = ChargePolicy(limited: true, limit: 80)
        // Above the limit macOS runs on the battery to get down to it.
        #expect(line(.onHold, nil, 0, held) == "Draining to 80%")
        #expect(line(.onHold, nil, -12.2, held) == "Draining to 80% at 12 W")
        // At the limit it holds.
        func atLimit(_ watts: Double?) -> String? {
            Format.chargeLine(.onHold, percent: 80, timeToFull: nil, batteryWatts: watts, policy: held)
        }
        #expect(atLimit(0) == "Holding at 80%")
        #expect(atLimit(-21.4) == "Holding at 80% · Draining at 21 W")
        // macOS didn't say where it stops: the level it is at now.
        #expect(line(.onHold, nil, 0, ChargePolicy(limited: true)) == "Holding at 82%")
        #expect(line(.charging, 20, 38, held) == "Charging to 80% at 38 W · 0:20 left")
        #expect(line(.charging, nil, 38, ChargePolicy(limited: true)) == "Charging at 38 W")
        let full = ChargePolicy(chargingToFull: true)
        #expect(line(.charging, 49, 38, full) == "Charging to Full at 38 W · 0:49 left")
        #expect(line(.charging, nil, nil, full) == "Charging to Full")
        #expect(line(.charged, nil, 0, full) == "Fully Charged")
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
