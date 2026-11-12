import Foundation

enum Format {
    /// 220 → "3:40"
    static func clock(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// "−70m", "−40s"
    static func cost(_ minutes: Double) -> String {
        let s = max(1, Int((minutes * 60).rounded()))
        return minutes >= 1 || s >= 60 ? "−\(max(1, Int(minutes.rounded())))m" : "−\(s)s"
    }

    /// "+70 min", "+40 sec"
    static func gain(_ minutes: Double) -> String {
        let s = max(1, Int((minutes * 60).rounded()))
        return minutes >= 1 || s >= 60 ? "+\(max(1, Int(minutes.rounded()))) min" : "+\(s) sec"
    }

    /// "2.1 W", "0.3 W"
    static func watts(_ w: Double) -> String {
        w < 0.05 ? "<0.1 W" : w >= 9.95 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }

    /// The line under the power source while plugged in:
    /// "Charging at 38 W · Full in 1:20", "Charging to Full at 38 W · 0:49 left",
    /// "Holding at 80%". `batteryWatts` is what flows into the battery (positive)
    /// or out of it (negative). Plugged in but not charging, the battery can still
    /// be the one doing the work (a weak adapter, or macOS bringing the charge
    /// down to its limit); that is said too.
    static func chargeLine(_ state: PowerState, percent: Int, timeToFull: Double?, batteryWatts: Double?,
                           policy: ChargePolicy = ChargePolicy()) -> String? {
        switch state {
        case .charged:
            return "Fully Charged"
        case .charging:
            let rate = batteryWatts.flatMap { $0 >= 1 ? " at \(Int($0.rounded())) W" : nil } ?? ""
            if policy.limited, let limit = policy.limit {
                return "Charging to \(limit)%" + rate + (timeToFull.map { " · \(clock($0)) left" } ?? "")
            }
            if policy.chargingToFull {
                return "Charging to Full" + rate + (timeToFull.map { " · \(clock($0)) left" } ?? "")
            }
            return "Charging" + rate + (timeToFull.map { " · Full in \(clock($0))" } ?? "")
        case .onHold:
            let drain = batteryWatts.flatMap { $0 <= -2 ? " · Draining at \(Int((-$0).rounded())) W" : nil } ?? ""
            return (policy.limited ? "Holding at \(policy.limit ?? percent)%" : "Not Charging") + drain
        case .battery, .noBattery:
            return nil
        }
    }

    /// 0.33 → "about a third of", 0.41 → "about 40% of"
    static func shareOf(_ share: Double) -> String {
        let named: [(Double, String)] = [(0.25, "a quarter"), (1.0 / 3, "a third"), (0.5, "half"),
                                         (2.0 / 3, "two thirds"), (0.75, "three quarters")]
        if let n = named.first(where: { abs($0.0 - share) <= 0.03 }) { return "about \(n.1) of" }
        return "about \(Int((share * 20).rounded()) * 5)% of"
    }

    /// 40 → "40 minutes", 70 → "1 hour 10 minutes". Rounded to 5 minutes from 10 up.
    static func approxDuration(_ minutes: Double) -> String {
        let m = minutes >= 10 ? Int((minutes / 5).rounded()) * 5 : max(1, Int(minutes.rounded()))
        let h = m / 60, rest = m % 60
        var parts: [String] = []
        if h > 0 { parts.append(h == 1 ? "1 hour" : "\(h) hours") }
        if rest > 0 || h == 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }

    /// The notification text.
    static func hogMessage(name: String, share: Double, gainMinutes: Double) -> String {
        "\(name) is using \(shareOf(share)) your battery power. Quitting it would add about \(approxDuration(gainMinutes))."
    }
}
