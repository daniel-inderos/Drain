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
}
