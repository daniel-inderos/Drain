import Foundation

/// One app's draw at one moment, as the watcher sees it.
struct PowerHog {
    let id: String
    let watts: Double
    /// Minutes of battery quitting it would win back.
    let gainMinutes: Double
}

/// Decides when one app has been eating the battery for long enough to say so.
/// Pure and Foundation-only: the model feeds it a reading per sample and posts
/// the notification itself when `observe` names an app.
///
/// An app qualifies while all of these hold:
/// - it is at least 30% of the whole machine's draw (a clear outlier, not a fair share);
/// - it draws at least 3 W (a third of nothing is not worth a notification);
/// - quitting it would add at least 20 minutes.
/// It must qualify at every reading for 5 minutes straight (a spike or a
/// pause resets it), then it is named once, and not again for 4 hours.
/// Readings may be any distance apart (30 s closed, 2 s open); a gap over
/// 90 s (sleep, a stalled run loop) breaks the run, since nothing was seen.
struct HogWatcher {
    struct Rules {
        var minShare = 0.30
        var minWatts = 3.0
        var minGainMinutes = 20.0
        var sustainSeconds = 300.0
        var maxGapSeconds = 90.0
        var cooldownSeconds = 4.0 * 3600
    }

    var rules = Rules()
    private var qualifyingSince: [String: Double] = [:]
    private var lastSeen: Double?
    private var warnedAt: [String: Double] = [:]

    /// `now` is wall-clock seconds (it must keep counting through sleep).
    /// Returns the id of the app to warn about, or nil. Plugged in resets the
    /// runs but not the 4-hour memory, so replugging doesn't bring a repeat.
    /// With Drain's menu open nothing is said and runs restart afterwards:
    /// the user is already looking at the answer.
    mutating func observe(at now: Double, onBattery: Bool, menuOpen: Bool,
                          systemWatts: Double, apps: [PowerHog]) -> String? {
        guard onBattery, !menuOpen else {
            qualifyingSince = [:]
            lastSeen = nil
            return nil
        }
        if let last = lastSeen, now < last || now - last > rules.maxGapSeconds { qualifyingSince = [:] }
        lastSeen = now

        let qualifying = systemWatts > 0 ? apps.filter {
            $0.watts / systemWatts >= rules.minShare && $0.watts >= rules.minWatts
                && $0.gainMinutes >= rules.minGainMinutes
        } : []
        let ids = Set(qualifying.map(\.id))
        qualifyingSince = qualifyingSince.filter { ids.contains($0.key) }
        for id in ids where qualifyingSince[id] == nil { qualifyingSince[id] = now }

        let due = qualifying.filter { hog in
            guard now - (qualifyingSince[hog.id] ?? now) >= rules.sustainSeconds else { return false }
            guard let warned = warnedAt[hog.id] else { return true }
            return now < warned || now - warned >= rules.cooldownSeconds
        }
        guard let pick = due.max(by: { $0.watts < $1.watts }) else { return nil }
        warnedAt[pick.id] = now
        return pick.id
    }
}
