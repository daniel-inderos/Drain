import AppKit
import SwiftUI

enum PowerState: Equatable {
    case battery, charging, charged, onHold, noBattery
    var onAC: Bool { self != .battery }
}

struct AppDrain: Identifiable, Equatable {
    let id: String          // resolved bundle path
    let pid: pid_t
    let name: String
    let icon: NSImage
    let color: Color
    var watts: Double
    /// What the slice's width is based on. Frozen while the menu is open so the
    /// slice under your cursor never slides away before you grab it.
    var layoutWatts: Double
    /// Minutes of battery you get back by quitting this app. Plugged in, that's
    /// against the time you'd have if you unplugged now.
    var gainMinutes: Double
    /// False only when there's no battery estimate at all (no battery, or no reading yet).
    var hasEstimate: Bool

    /// Under the slice: "−18m".
    var costLabel: String {
        hasEstimate ? (gainMinutes >= 0.05 ? Format.cost(gainMinutes) : "") : Format.watts(watts)
    }

    /// On the pulled-out tile: "+70 min".
    var gainTag: String {
        hasEstimate ? Format.gain(gainMinutes) : "−" + Format.watts(watts)
    }
}

@MainActor
final class DrainModel: ObservableObject {
    @Published private(set) var state: PowerState = .noBattery
    @Published private(set) var percent = 0
    /// Time left on battery: right now on battery, or if you unplugged now when
    /// plugged in. nil while unknown.
    @Published private(set) var headline: Double?
    /// While charging: minutes until full, from macOS.
    @Published private(set) var timeToFull: Double?
    @Published private(set) var apps: [AppDrain] = []
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// What's been won back by apps quit since the menu opened.
    @Published private(set) var sessionMinutes: Double = 0
    @Published private(set) var sessionWatts: Double = 0
    @Published var draggingID: String?

    /// While the menu is open the slices keep their place; only their numbers move.
    var menuOpen = false
    /// Called around the admin password prompt so the menu doesn't close under it.
    var modalHook: ((Bool) -> Void)?

    private let sampler = EnergySampler()
    private let coalitions = CoalitionSampler()
    private let queue = DispatchQueue(label: "drain.sampler", qos: .utility)
    private var timer: Timer?
    private var systemWatts: Double?
    private var remainingWh: Double = 0
    private var nativeTimeToEmpty: Double?
    private var nativeTimeToFull: Double?
    private var lastAccumulator: (sum: Double, count: Double)?
    private var appWatts: [String: Double] = [:]
    private var quitting: [String: Date] = [:]
    private var colors: [String: Color] = [:]
    private var resolved: [String: String] = [:]

    private let maxSegments = 5
    /// Smoothing time constants, in seconds. Long enough that a spike from one
    /// busy moment doesn't swing the estimate.
    private let systemRiseTau = 8.0
    private let systemFallTau = 60.0
    /// Apps rise fast (a heavy app shows up within seconds) and fall slowly (it
    /// doesn't vanish the moment it pauses).
    private let appRiseTau = 5.0
    private let appFallTau = 30.0

    func start() {
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            onMainRunLoop { self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        tick()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes, so it keeps ticking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let running = quittableApps()
        let targets = running.map { (key: resolve($0.bundleURL!.path), pid: $0.processIdentifier) }
        let sampler = self.sampler, coalitions = self.coalitions
        queue.async {
            let sample: (watts: [String: Double], seconds: Double)
            if coalitions.available {
                sample = coalitions.sample(targets)
            } else {
                // Fallback: attribute processes to the .app bundle they live in.
                sample = sampler.sample()
            }
            let battery = BatteryReader.read()
            onMainRunLoop { self.ingest(sample.watts, seconds: sample.seconds, battery, running: running) }
        }
    }

    /// Apps you can see and quit: regular apps plus third-party menu bar apps.
    private func quittableApps() -> [NSRunningApplication] {
        let me = getpid()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, app.processIdentifier != me, app.bundleURL != nil,
                  app.bundleIdentifier != "com.apple.finder" else { return false }
            switch app.activationPolicy {
            case .regular: return true
            case .accessory: return !(app.bundleIdentifier ?? "").hasPrefix("com.apple.")
            default: return false
            }
        }
    }

    private func ingest(_ raw: [String: Double], seconds: Double, _ battery: BatterySnapshot,
                        running: [NSRunningApplication]) {
        let newState: PowerState =
            !battery.hasBattery ? .noBattery
            : !battery.onAC ? .battery
            : battery.charging ? .charging
            : battery.charged ? .charged : .onHold
        let stateChanged = newState != state
        if stateChanged { state = newState }
        percent = battery.percent
        remainingWh = battery.remainingWh
        nativeTimeToEmpty = battery.timeToEmpty
        nativeTimeToFull = battery.timeToFull

        // Whole-machine draw: average since the last sample, then smoothed.
        var load = battery.systemWatts
        if let sum = battery.loadAccumulator, let count = battery.loadSamples {
            if let last = lastAccumulator, count > last.count, sum >= last.sum {
                load = (sum - last.sum) / (count - last.count) / 1000
            }
            lastAccumulator = (sum, count)
        }
        if let load, load > 0 {
            // Rises as quickly as app readings do, so an app can't briefly look
            // bigger than the whole Mac.
            systemWatts = smooth(systemWatts, load, dt: seconds,
                                 tau: load > (systemWatts ?? 0) ? systemRiseTau : systemFallTau)
        }

        // Per-app draw.
        var byBundle: [String: Double] = [:]
        for (path, w) in raw { byBundle[resolve(path), default: 0] += w }

        // The very first sample has nothing to diff against; skip it rather than seed zeros.
        if seconds > 0 {
            var next: [String: Double] = [:]
            for app in running {
                let key = resolve(app.bundleURL!.path)
                let w = byBundle[key] ?? 0
                let old = appWatts[key]
                next[key] = smooth(old, w, dt: seconds, tau: w > (old ?? 0) ? appRiseTau : appFallTau)
            }
            appWatts = next
        }

        let now = Date()
        quitting = quitting.filter { now.timeIntervalSince($0.value) < 8 }

        guard draggingID == nil else { return }
        let total = totalWatts

        let candidates: [AppDrain] = running.compactMap { app in
            let key = resolve(app.bundleURL!.path)
            guard quitting[key] == nil, let w = appWatts[key] else { return nil }
            return AppDrain(
                id: key, pid: app.processIdentifier,
                name: app.localizedName ?? (key as NSString).lastPathComponent,
                icon: app.icon ?? NSWorkspace.shared.icon(forFile: key),
                color: color(for: key, icon: app.icon),
                watts: w, layoutWatts: w, gainMinutes: gain(removing: w, from: total),
                hasEstimate: minutesLeft(at: total) != nil)
        }

        let listed = Set(apps.map(\.id))
        // Easier to stay on than to get on, so apps hovering at the edge don't flicker.
        let eligible = candidates.filter { $0.watts >= (listed.contains($0.id) ? 0.01 : 0.03) }
        var nextApps: [AppDrain]
        if menuOpen && !stateChanged {
            // Slices you're looking at keep their place; only their numbers move.
            // Free spots can still fill up at the end.
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            nextApps = apps.compactMap { old in
                byID[old.id].map { var a = $0; a.layoutWatts = old.layoutWatts; return a }
            }
            let newcomers = eligible.filter { !listed.contains($0.id) }.sorted { $0.watts > $1.watts }
            for app in newcomers {
                if nextApps.count < maxSegments {
                    nextApps.append(app)
                } else if let weakest = nextApps.indices.min(by: { nextApps[$0].watts < nextApps[$1].watts }),
                          app.watts > max(0.1, nextApps[weakest].watts * 2) {
                    // A heavy newcomer bumps a light slice instead of waiting for the menu to close.
                    nextApps.remove(at: weakest)
                    nextApps.append(app)
                }
            }
        } else {
            nextApps = Array(stableOrder(eligible).prefix(maxSegments))
        }

        let nextHeadline = minutesLeft(at: total)
        if timeToFull.map({ abs($0 - (nativeTimeToFull ?? -99)) >= 2 }) ?? (nativeTimeToFull != nil) {
            timeToFull = nativeTimeToFull
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            if nextApps.map(\.id) != apps.map(\.id) || nextApps != apps { apps = nextApps }
            if stateChanged || shouldMove(headline, to: nextHeadline) { headline = nextHeadline }
        }
    }

    /// Biggest drain first, but neighbours only swap once one clearly overtakes the other.
    private func stableOrder(_ candidates: [AppDrain]) -> [AppDrain] {
        let previous = apps.map(\.id)
        var ordered = candidates.sorted {
            let a = previous.firstIndex(of: $0.id) ?? Int.max
            let b = previous.firstIndex(of: $1.id) ?? Int.max
            return a != b ? a < b : $0.watts > $1.watts
        }
        var swapped = true
        while swapped {
            swapped = false
            for i in 0..<max(0, ordered.count - 1) where ordered[i + 1].watts > ordered[i].watts * 1.4 {
                ordered.swapAt(i, i + 1)
                swapped = true
            }
        }
        return ordered
    }

    /// The big number only moves when the change is worth noticing.
    private func shouldMove(_ old: Double?, to new: Double?) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        return abs(new - old) >= max(3, old * 0.03)
    }

    private func smooth(_ old: Double?, _ new: Double, dt: Double, tau: Double) -> Double {
        guard let old, dt > 0 else { return new }
        return old + (1 - exp(-dt / tau)) * (new - old)
    }

    // MARK: - Battery math

    private var totalWatts: Double {
        systemWatts ?? (appWatts.values.reduce(0, +) + 5)
    }

    /// Time left on battery at a given draw. On battery it's anchored to macOS's
    /// own estimate so the number matches the system's. Plugged in, it's what the
    /// charge in the battery would last at what the Mac is drawing right now.
    private func minutesLeft(at watts: Double) -> Double? {
        guard state != .noBattery, watts > 0.5 else { return nil }
        let current = totalWatts
        if state == .battery, let native = nativeTimeToEmpty, current > 0.5 { return native * current / watts }
        guard remainingWh > 0 else { return nil }
        return remainingWh / watts * 60
    }

    private func gain(removing w: Double, from total: Double) -> Double {
        // Quitting one app can't take the Mac below a quarter of what it draws now
        // (the display, radios and the system itself keep running).
        let floor = max(0.6, total * 0.25)
        guard let before = minutesLeft(at: total), let after = minutesLeft(at: max(floor, total - w)) else { return 0 }
        return max(0, after - before)
    }

    // MARK: - Actions

    func quit(_ app: AppDrain) {
        quitting[app.id] = Date()
        appWatts[app.id] = nil
        let gained = app.gainMinutes
        if let sys = systemWatts { systemWatts = max(0.6, sys - app.watts) }
        let total = totalWatts

        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            sessionMinutes += gained
            sessionWatts += app.watts
            apps.removeAll { $0.id == app.id }
            apps = apps.map { var a = $0; a.gainMinutes = gain(removing: a.watts, from: total); return a }
            headline = minutesLeft(at: total)
            draggingID = nil
        }
        // Test runs set DRAIN_ONLY_QUIT to a bundle id so a mis-aimed drag can't quit a real app.
        if let only = ProcessInfo.processInfo.environment["DRAIN_ONLY_QUIT"],
           NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier != only {
            debugLog("refused to quit \(app.name) (DRAIN_ONLY_QUIT=\(only))")
            return
        }
        Quitter.quit(pid: app.pid)
    }

    func setLowPower(_ on: Bool) {
        lowPower = on
        Task.detached {
            if LowPowerMode.setQuietly(on) { return }
            onMainRunLoop {
                // First time only: macOS asks for your password and Drain installs
                // a rule so later switches don't need it. Close the menu first so
                // the prompt isn't stuck underneath it.
                self.modalHook?(true)
                onMainRunLoop(after: 0.35) {
                    let ok = LowPowerMode.installRuleAndSet(on)
                    self.lowPower = ok ? on : ProcessInfo.processInfo.isLowPowerModeEnabled
                    self.modalHook?(false)
                }
            }
        }
    }

    func menuClosed() {
        menuOpen = false
        sessionMinutes = 0
        sessionWatts = 0
    }

    // MARK: - Helpers

    private func resolve(_ path: String) -> String {
        if let r = resolved[path] { return r }
        let r = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        resolved[path] = r
        return r
    }

    private func color(for key: String, icon: NSImage?) -> Color {
        if let c = colors[key] { return c }
        let c = Color(nsColor: IconColor.dominant(icon ?? NSWorkspace.shared.icon(forFile: key)))
        colors[key] = c
        return c
    }
}

/// Runs work on the main thread in a way that also happens while a menu is open.
/// Menu tracking holds off the main dispatch queue (and so `Task { @MainActor }`),
/// but it keeps servicing the run loop's common modes.
func onMainRunLoop(_ block: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// Same, after a delay.
func onMainRunLoop(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
    let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated(block) }
    RunLoop.main.add(timer, forMode: .common)
}

func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["DRAIN_DEBUG"] != nil else { return }
    FileHandle.standardError.write((message() + "\n").data(using: .utf8)!)
}

enum Format {
    /// 220 → "3:40"
    static func clock(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// "−70m", "−40s"
    static func cost(_ minutes: Double) -> String {
        minutes >= 1 ? "−\(Int(minutes.rounded()))m" : "−\(max(1, Int((minutes * 60).rounded())))s"
    }

    /// "+70 min", "+40 sec"
    static func gain(_ minutes: Double) -> String {
        minutes >= 1 ? "+\(Int(minutes.rounded())) min" : "+\(max(1, Int((minutes * 60).rounded()))) sec"
    }

    /// "2.1 W", "0.3 W"
    static func watts(_ w: Double) -> String {
        w < 0.05 ? "<0.1 W" : w >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }
}

enum IconColor {
    /// The icon's most prominent saturated hue, tuned to sit well as a segment fill.
    static func dominant(_ image: NSImage) -> NSColor {
        let side = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return .systemBlue }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var bins = [(w: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                let w = s * s * a * v
                guard w > 0.03 else { continue }
                let i = min(11, Int(h * 12))
                bins[i].w += w
                bins[i].r += c.redComponent * w
                bins[i].g += c.greenComponent * w
                bins[i].b += c.blueComponent * w
            }
        }

        guard let best = bins.max(by: { $0.w < $1.w }), best.w > 1 else {
            return NSColor(deviceHue: 0.62, saturation: 0.18, brightness: 0.58, alpha: 1)
        }
        let avg = NSColor(deviceRed: best.r / best.w, green: best.g / best.w, blue: best.b / best.w, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(deviceHue: h, saturation: min(0.82, max(0.5, s)), brightness: 0.8, alpha: 1)
    }
}
