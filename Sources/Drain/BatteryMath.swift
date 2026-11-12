import Foundation

/// Anything the ordering logic can rank: an id and a draw.
protocol WattsRanked {
    var id: String { get }
    var watts: Double { get }
}

/// How long the battery lasts at a given draw. One rule for every state, so the
/// headline and the per-slice gains always agree with each other.
///
/// Time left = `calibration` x charge / draw. Plugged in `calibration` is 1: it is
/// simply what the charge in the battery would last at the draw right now. On
/// battery it is the factor that makes this formula match macOS's own estimate
/// (see `calibration(native:remainingWh:watts:)`). The caller holds that factor
/// steady instead of recomputing it each tick, so when the draw suddenly drops
/// (an app was quit) the number rises at once, and the factor only drifts to
/// the new reading once macOS's estimate has caught up.
struct RuntimeEstimate {
    var hasBattery: Bool
    /// Energy left in the battery, in watt-hours.
    var remainingWh: Double
    /// 1 when there is nothing to calibrate against.
    var calibration: Double = 1

    func minutesLeft(at watts: Double) -> Double? {
        guard hasBattery, watts > 0.5, remainingWh > 0 else { return nil }
        return calibration * remainingWh / watts * 60
    }

    /// Minutes won back by removing `w` watts from a Mac drawing `total`.
    func gain(removing w: Double, from total: Double) -> Double {
        // Quitting one app can't take the Mac below a quarter of what it draws now
        // (the display, radios and the system itself keep running).
        let floor = max(0.6, total * 0.25)
        guard let before = minutesLeft(at: total),
              let after = minutesLeft(at: max(floor, total - w)) else { return 0 }
        return max(0, after - before)
    }
}

enum BatteryMath {
    /// Moves `old` toward `new` by the share of `tau` that `dt` seconds covers.
    /// With nothing to diff against (no old value, or dt of 0) it just takes `new`.
    static func smooth(_ old: Double?, _ new: Double, dt: Double, tau: Double) -> Double {
        guard let old, dt > 0 else { return new }
        return old + (1 - exp(-dt / tau)) * (new - old)
    }

    /// The big number only moves when the change is worth noticing.
    static func shouldMove(_ old: Double?, to new: Double?) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        return abs(new - old) >= max(3, old * 0.03)
    }

    /// The factor that makes `remainingWh / watts` agree with macOS's estimate
    /// `native` (minutes), or nil when either is missing. Clamped, because a
    /// wild reading should never make the headline absurd.
    static func calibration(native: Double?, remainingWh: Double, watts: Double) -> Double? {
        guard let native, native > 0, remainingWh > 0, watts > 0.5 else { return nil }
        return min(2.5, max(0.4, native / (remainingWh / watts * 60)))
    }

    /// Minutes until the battery reaches `target` percent at the rate it is charging
    /// now, for when macOS has no estimate of its own (the first minute, or a
    /// charge limit). Up to 80% the rate holds. Above that it tapers, here taken
    /// as falling in a straight line to 15% of the 80% rate at full, which puts
    /// 80 to 100% at about 2.2 times the straight-line time, close to what macOS
    /// itself says. Rounded to 5 minutes, because it is no finer than that.
    static func minutesToCharge(remainingWh: Double, fullWh: Double, to target: Int, watts: Double?) -> Double? {
        guard let watts, watts >= 1, fullWh > 0, remainingWh > 0 else { return nil }
        let knee = 0.8, floorShare = 0.15
        let from = remainingWh / fullWh, to = min(1, Double(target) / 100)
        guard to - from > 0.005 else { return nil }
        /// The rate at a level, as a share of the rate below the knee.
        func rate(_ level: Double) -> Double { 1 - (1 - floorShare) * max(0, level - knee) / (1 - knee) }
        // `watts` was measured at `from`, so the full-speed rate is watts / rate(from).
        let fullSpeed = watts / rate(from)
        var hours = max(0, min(to, knee) - from) * fullWh / fullSpeed
        if to > knee {
            let span = (1 - knee) / (1 - floorShare)
            hours += fullWh / fullSpeed * span * log(rate(max(from, knee)) / rate(to))
        }
        let minutes = hours * 60
        guard minutes.isFinite else { return nil }
        return minutes >= 10 ? (minutes / 5).rounded() * 5 : max(1, minutes.rounded())
    }

    /// Biggest drain first, but neighbours only swap once one clearly overtakes
    /// the other. `previous` is the ids in their current on-screen order.
    static func stableOrder<T: WattsRanked>(_ candidates: [T], previous: [String]) -> [T] {
        var ordered = candidates.sorted {
            let a = previous.firstIndex(of: $0.id) ?? Int.max
            let b = previous.firstIndex(of: $1.id) ?? Int.max
            return a != b ? a < b : $0.watts > $1.watts
        }
        // Capped at one pass per item: enough for any real input, and a negative
        // reading (which would swap back and forth forever) can't hang the app.
        var swapped = true, passes = 0
        while swapped, passes <= ordered.count {
            swapped = false
            passes += 1
            for i in 0..<max(0, ordered.count - 1) where ordered[i + 1].watts > ordered[i].watts * 1.4 {
                ordered.swapAt(i, i + 1)
                swapped = true
            }
        }
        return ordered
    }
}
