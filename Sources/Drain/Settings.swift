import Foundation

/// Drain's three options, all off by default. The only place that touches
/// UserDefaults for them, so the keys are in one spot.
final class DrainSettings {
    enum Key {
        static let showTimeLeft = "showTimeLeftInMenuBar"
        static let warnAboutHogs = "warnAboutPowerHungryApps"
        /// Dictionary of bundle identifier -> display name. The name is kept so an
        /// ignored app that isn't running can still be listed and un-ignored.
        static let ignoredApps = "neverSuggestQuittingApps"
    }

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var showTimeLeft: Bool {
        get { defaults.bool(forKey: Key.showTimeLeft) }
        set { defaults.set(newValue, forKey: Key.showTimeLeft) }
    }

    var warnAboutHogs: Bool {
        get { defaults.bool(forKey: Key.warnAboutHogs) }
        set { defaults.set(newValue, forKey: Key.warnAboutHogs) }
    }

    var ignoredApps: [String: String] {
        get { defaults.dictionary(forKey: Key.ignoredApps) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.ignoredApps) }
    }
}
