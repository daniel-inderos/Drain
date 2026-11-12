import AppKit
import IOKit.ps
import SwiftUI

enum PowerState: Equatable {
    case battery, charging, charged, onHold, noBattery
    var onAC: Bool { self != .battery }
}

struct AppDrain: Identifiable, Equatable {
    let id: String          // resolved bundle path
    /// What the ignore list is keyed by.
    let bundleID: String?
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

extension AppDrain: WattsRanked {}

/// A quit Drain has sent but not yet seen happen. The slice and the numbers
/// already moved (so it feels instant); this is what it takes to undo that.
private struct PendingQuit {
    let app: AppDrain
    let sentAt: Date
    /// False when DRAIN_ONLY_QUIT refused it, so there is nothing to wait for.
    let sent: Bool
    let creditMinutes: Double
    let creditWatts: Double
    /// How much `systemWatts` the quit took off, to put back on a rollback.
    let removedWatts: Double
    /// Which menu session the credit went into; a later session isn't touched.
    let epoch: Int
    var revealed = false
}

@MainActor
final class DrainModel: ObservableObject {
    @Published private(set) var state: PowerState = .noBattery
    @Published private(set) var percent = 0
    /// Time left on battery: right now on battery, or if you unplugged now when
    /// plugged in. nil while unknown. Moves at once when an app is quit.
    @Published private(set) var headline: Double?
    /// While charging: minutes until full, from macOS.
    @Published private(set) var timeToFull: Double?
    @Published private(set) var apps: [AppDrain] = []
    /// Eligible apps that don't fit in the pill, biggest draw first.
    @Published private(set) var otherApps: [AppDrain] = []
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// What's been won back by apps quit since the menu opened.
    @Published private(set) var sessionMinutes: Double = 0
    @Published private(set) var sessionWatts: Double = 0
    @Published var draggingID: String?
    /// Apps never suggested for quitting: bundle identifier -> display name.
    @Published private(set) var ignoredApps: [String: String]

    /// While the menu is open the slices keep their place; only their numbers move.
    /// Also sets the pace: fast while you're looking, slow otherwise.
    var menuOpen = false {
        didSet {
            guard menuOpen != oldValue else { return }
            if menuOpen {
                // Counters are cleared here rather than on close, so a quit that is
                // still pending when the menu closes keeps its credit until it settles.
                if sessionStale { resetSession() }
                // Fresh numbers right away, unless a sample has only just run.
                schedule(fast: true)
                if Date().timeIntervalSince(lastTickAt) > 1 { tick() }
            } else {
                sessionStale = true
                schedule(fast: false)
            }
        }
    }
    /// Called when Drain needs the menu out of the way: the admin password prompt,
    /// or an app that is still asking something after being told to quit.
    var modalHook: ((Bool) -> Void)?

    let settings: DrainSettings
    private var hogWatcher = HogWatcher()
    private let sampler = PowerSampler()
    private let queue = DispatchQueue(label: "drain.sampler", qos: .utility)
    private var timer: Timer?
    private var watchdog: Timer?
    private var powerSource: CFRunLoopSource?
    private var powerTickPending = false
    private var lastTickAt = Date.distantPast
    private var systemWatts: Double?
    private var remainingWh: Double = 0
    private var nativeTimeToEmpty: Double?
    private var nativeTimeToFull: Double?
    /// See `RuntimeEstimate`. nil until macOS has given an estimate on battery.
    private var calibration: Double?
    private var lastQuitAt = Date.distantPast
    private var lastAccumulator: (sum: Double, count: Double)?
    private var appWatts: [String: Double] = [:]
    private var quitting: [String: Date] = [:]
    private var pendingQuits: [String: PendingQuit] = [:]
    private var sessionStale = false
    private var sessionEpoch = 0
    private var colors: [String: Color] = [:]
    private var resolved: [String: String] = [:]

    private let maxSegments = 5
    /// Seconds between samples with the menu open and closed. Closed, only the
    /// icon is visible. The energy counters are cumulative, so a long gap still
    /// averages correctly.
    private let fastInterval = 2.0
    private let slowInterval = 30.0
    /// An app that hasn't quit this long after being asked is probably showing a
    /// question; bring it forward. If it's still there after the longer wait, it
    /// refused (or you cancelled) and the credit is taken back.
    private let revealAfter = 3.0   // big apps take a couple of seconds to quit normally
    private let giveUpAfter = 15.0
    /// Smoothing time constants, in seconds. Long enough that a spike from one
    /// busy moment doesn't swing the estimate.
    private let systemRiseTau = 8.0
    private let systemFallTau = 60.0
    /// Apps rise fast (a heavy app shows up within seconds) and fall slowly (it
    /// doesn't vanish the moment it pauses).
    private let appRiseTau = 5.0
    private let appFallTau = 30.0
    /// How slowly the on-battery calibration follows macOS's estimate, and how
    /// long it stays put after a quit while macOS's estimate catches up.
    private let calibrationTau = 60.0
    private let calibrationHold = 120.0

    init(settings: DrainSettings = DrainSettings()) {
        self.settings = settings
        ignoredApps = settings.ignoredApps
    }

    func start() {
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            onMainRunLoop { self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        watchPowerSource()
        tick()
        schedule(fast: menuOpen)
    }

    private func schedule(fast: Bool) {
        timer?.invalidate()
        let timer = Timer(timeInterval: fast ? fastInterval : slowInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes, so it keeps ticking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// With the menu closed the slow timer would take up to 30 s to notice a
    /// plug or unplug, so macOS tells us instead.
    private func watchPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let model = Unmanaged<DrainModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.powerSourceChanged() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    /// Plugging in fires a burst of notifications; one sample after it settles is enough.
    private func powerSourceChanged() {
        guard !powerTickPending else { return }
        powerTickPending = true
        onMainRunLoop(after: 0.5) { [weak self] in
            self?.powerTickPending = false
            self?.tick()
        }
    }

    private func tick() {
        lastTickAt = Date()
        let running = quittableApps()
        let targets = running.map { (key: resolve($0.bundleURL!.path), pid: $0.processIdentifier) }
        let sampler = self.sampler
        queue.async {
            let sample = sampler.sample(targets)
            onMainRunLoop { self.ingest(sample.watts, seconds: sample.seconds, sample.battery, running: running) }
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
            systemWatts = BatteryMath.smooth(systemWatts, load, dt: seconds,
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
                next[key] = BatteryMath.smooth(old, w, dt: seconds, tau: w > (old ?? 0) ? appRiseTau : appFallTau)
            }
            appWatts = next
        }

        trackCalibration(seconds: seconds)
        let now = Date()
        quitting = quitting.filter { now.timeIntervalSince($0.value) < 8 }

        if timeToFull.map({ abs($0 - (nativeTimeToFull ?? -99)) >= 2 }) ?? (nativeTimeToFull != nil) {
            timeToFull = nativeTimeToFull
        }
        publish(running: running, stateChanged: stateChanged, forceHeadline: false)
        watchForHog()
    }

    /// Feeds the sustained-draw watcher and posts its warning, if any.
    private func watchForHog() {
        guard settings.warnAboutHogs, HogNotifier.available else { return }
        let total = totalWatts
        let all = apps + otherApps
        let hogs = all.map { PowerHog(id: $0.id, watts: $0.watts, gainMinutes: $0.hasEstimate ? $0.gainMinutes : 0) }
        guard let id = hogWatcher.observe(at: Date().timeIntervalSince1970, onBattery: state == .battery,
                                          menuOpen: menuOpen, systemWatts: total, apps: hogs),
              let app = all.first(where: { $0.id == id }) else { return }
        HogNotifier.shared.post(
            title: "Drain",
            body: Format.hogMessage(name: app.name, share: app.watts / total, gainMinutes: app.gainMinutes),
            id: "hog-\(id)")
    }

    /// Adds or removes an app from the ignore list; the pill and lists follow at once.
    func setIgnored(_ bundleID: String, name: String, _ ignored: Bool) {
        var list = ignoredApps
        if ignored { list[bundleID] = name } else { list[bundleID] = nil }
        guard list != ignoredApps else { return }
        ignoredApps = list
        settings.ignoredApps = list
        publish(running: quittableApps(), stateChanged: false, forceHeadline: false)
    }

    /// Keeps the on-battery factor close to macOS's estimate, slowly. It is left
    /// alone just after a quit: macOS's estimate hasn't caught up with the lower
    /// draw yet, and following it now would pull the headline straight back down.
    private func trackCalibration(seconds: Double) {
        guard state == .battery else { calibration = nil; return }
        guard Date().timeIntervalSince(lastQuitAt) > calibrationHold, pendingQuits.isEmpty,
              let raw = BatteryMath.calibration(native: nativeTimeToEmpty, remainingWh: remainingWh, watts: totalWatts)
        else { return }
        calibration = calibration.map { BatteryMath.smooth($0, raw, dt: seconds, tau: calibrationTau) } ?? raw
    }

    /// Turns the readings into what the menu shows: the slices, the overflow list, the headline.
    private func publish(running: [NSRunningApplication], stateChanged: Bool, forceHeadline: Bool) {
        guard draggingID == nil else { return }
        let total = totalWatts
        let hasEstimate = minutesLeft(at: total) != nil

        // Two processes can come from the same bundle (an app launched twice, or via a
        // symlink); they share one reading, so offer the bundle once.
        var seen = Set<String>()
        let candidates: [AppDrain] = running.compactMap { app in
            let key = resolve(app.bundleURL!.path)
            guard seen.insert(key).inserted, quitting[key] == nil, pendingQuits[key] == nil, let w = appWatts[key] else { return nil }
            // Ignored apps still count in the whole-machine draw; they just aren't offered.
            if let bundleID = app.bundleIdentifier, ignoredApps[bundleID] != nil { return nil }
            return AppDrain(
                id: key, bundleID: app.bundleIdentifier, pid: app.processIdentifier,
                name: app.localizedName ?? (key as NSString).lastPathComponent,
                icon: app.icon ?? NSWorkspace.shared.icon(forFile: key),
                color: color(for: key, icon: app.icon),
                watts: w, layoutWatts: w, gainMinutes: gain(removing: w, from: total),
                hasEstimate: hasEstimate)
        }

        let listed = Set(apps.map(\.id)).union(otherApps.map(\.id))
        // Easier to stay on than to get on, so apps hovering at the edge don't flicker.
        let eligible = candidates.filter { $0.watts >= (listed.contains($0.id) ? 0.01 : 0.03) }
        var nextApps: [AppDrain]
        if menuOpen && !stateChanged {
            // Slices you're looking at keep their place; only their numbers move.
            // Free spots can still fill up at the end.
            let shown = Set(apps.map(\.id))
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            nextApps = apps.compactMap { old in
                byID[old.id].map { var a = $0; a.layoutWatts = old.layoutWatts; return a }
            }
            let newcomers = eligible.filter { !shown.contains($0.id) }.sorted { $0.watts > $1.watts }
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
            nextApps = Array(BatteryMath.stableOrder(eligible, previous: apps.map(\.id)).prefix(maxSegments))
        }
        let shownIDs = Set(nextApps.map(\.id))
        let nextOthers = eligible.filter { !shownIDs.contains($0.id) }.sorted { $0.watts > $1.watts }

        let nextHeadline = minutesLeft(at: total)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            if nextApps != apps { apps = nextApps }
            if nextOthers != otherApps { otherApps = nextOthers }
            if stateChanged || forceHeadline || BatteryMath.shouldMove(headline, to: nextHeadline) { headline = nextHeadline }
        }
    }

    // MARK: - Battery math

    private var totalWatts: Double {
        systemWatts ?? (appWatts.values.reduce(0, +) + 5)
    }

    /// One rule in every state: charge / draw, scaled by `calibration` on battery
    /// so it matches macOS's estimate in steady state. Plugged in it's the time
    /// you'd have if you unplugged now.
    private var estimate: RuntimeEstimate {
        RuntimeEstimate(hasBattery: state != .noBattery, remainingWh: remainingWh,
                        calibration: state == .battery ? (calibration ?? 1) : 1)
    }

    private func minutesLeft(at watts: Double) -> Double? { estimate.minutesLeft(at: watts) }

    private func gain(removing w: Double, from total: Double) -> Double {
        estimate.gain(removing: w, from: total)
    }

    // MARK: - Actions

    func quit(_ app: AppDrain) {
        let now = Date()
        quitting[app.id] = now
        lastQuitAt = now
        appWatts[app.id] = nil
        var removed = 0.0
        if let sys = systemWatts {
            let lowered = max(0.6, sys - app.watts)
            removed = sys - lowered
            systemWatts = lowered
        }
        let total = totalWatts

        // Test runs set DRAIN_ONLY_QUIT to a bundle id so a mis-aimed drag can't quit a real app.
        var refused = false
        if let only = ProcessInfo.processInfo.environment["DRAIN_ONLY_QUIT"],
           NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier != only {
            debugLog("refused to quit \(app.name) (DRAIN_ONLY_QUIT=\(only))")
            refused = true
        }

        // Optimistic: the slice leaves and the numbers move now. The watchdog
        // takes it all back if the app doesn't actually go.
        pendingQuits[app.id] = PendingQuit(
            app: app, sentAt: now, sent: !refused, creditMinutes: app.gainMinutes,
            creditWatts: app.watts, removedWatts: removed, epoch: sessionEpoch)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            sessionMinutes += app.gainMinutes
            sessionWatts += app.watts
            apps.removeAll { $0.id == app.id }
            otherApps.removeAll { $0.id == app.id }
            apps = apps.map { var a = $0; a.gainMinutes = gain(removing: a.watts, from: total); return a }
            otherApps = otherApps.map { var a = $0; a.gainMinutes = gain(removing: a.watts, from: total); return a }
            headline = minutesLeft(at: total)
            draggingID = nil
        }
        startWatchdog()
        if !refused { Quitter.quit(pid: app.pid) }
    }

    /// Checks every half second whether pending quits happened. Polling, because
    /// notifications and KVO can stall while the menu is tracking; the timer runs
    /// in common modes like the sampling one.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPendingQuits() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkPendingQuits() {
        let now = Date()
        for (id, p) in pendingQuits {
            if !isRunning(p.app) {
                pendingQuits[id] = nil          // it went; the credit stands
                continue
            }
            let age = now.timeIntervalSince(p.sentAt)
            if p.sent, !p.revealed, age >= revealAfter {
                pendingQuits[id]?.revealed = true
                reveal(p.app)
            }
            if age >= (p.sent ? giveUpAfter : revealAfter) { rollBack(p) }
        }
        if pendingQuits.isEmpty { watchdog?.invalidate(); watchdog = nil }
    }

    /// Same process, still alive. (A pid can be reused, so the bundle is checked too.)
    private func isRunning(_ app: AppDrain) -> Bool {
        guard let r = NSRunningApplication(processIdentifier: app.pid), !r.isTerminated,
              let url = r.bundleURL else { return false }
        return resolve(url.path) == app.id
    }

    /// The app hasn't quit, so it's probably asking something ("Save changes?")
    /// behind other windows. Bring it forward. The menu is closed too: while it's
    /// open it would swallow the first click meant for the sheet. That's safe for
    /// the numbers because the counters are cleared when the menu next opens, not
    /// when it closes, so other quits keep their "won back" until then.
    private func reveal(_ app: AppDrain) {
        guard let r = NSRunningApplication(processIdentifier: app.pid) else { return }
        modalHook?(true)
        r.activate(options: [.activateAllWindows])
        // Drain isn't frontmost, so macOS may ignore that; opening the app by URL
        // is what a Dock click does and always brings it forward.
        onMainRunLoop(after: 0.4) {
            guard !r.isTerminated, !r.isActive, let url = r.bundleURL else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The quit didn't happen: take the credit back and let the slice return.
    private func rollBack(_ p: PendingQuit) {
        debugLog("quit of \(p.app.name) did not happen; rolling back")
        pendingQuits[p.app.id] = nil
        quitting[p.app.id] = nil
        if let sys = systemWatts { systemWatts = sys + p.removedWatts }
        appWatts[p.app.id] = p.app.watts
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            if p.epoch == sessionEpoch {
                sessionMinutes = max(0, sessionMinutes - p.creditMinutes)
                sessionWatts = max(0, sessionWatts - p.creditWatts)
            }
            publish(running: quittableApps(), stateChanged: false, forceHeadline: true)
        }
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
        menuOpen = false   // the counters are cleared when it next opens
    }

    private func resetSession() {
        sessionStale = false
        sessionEpoch += 1
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
