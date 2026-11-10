import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Measures per-app power by diffing each process's cumulative energy counter
/// (`ri_energy_nj` from `proc_pid_rusage`). Helper processes are attributed to
/// the outermost `.app` bundle they live in, so Chrome's helpers count as Chrome.
final class EnergySampler: @unchecked Sendable {  // only used on the sampler queue
    private var last: [pid_t: (energy: UInt64, bundle: String)] = [:]
    private var lastTime: UInt64 = 0

    /// Watts per outermost `.app` bundle path, averaged since the previous call.
    func sample() -> (watts: [String: Double], seconds: Double) {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = lastTime == 0 ? 0 : Double(now - lastTime) / 1e9
        lastTime = now

        var current: [pid_t: (energy: UInt64, bundle: String)] = [:]
        var watts: [String: Double] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard rc == 0 else { continue }

            let prev = last[pid]
            let bundle = prev?.bundle ?? Self.bundlePath(for: pid) ?? ""
            current[pid] = (info.ri_energy_nj, bundle)

            guard !bundle.isEmpty, dt > 0, let prev, info.ri_energy_nj >= prev.energy else { continue }
            watts[bundle, default: 0] += Double(info.ri_energy_nj - prev.energy) / 1e9 / dt
        }
        last = current
        return (watts, dt)
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return Array(buffer.prefix(Int(max(0, filled))))
    }

    private static func bundlePath(for pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

struct BatterySnapshot {
    var hasBattery = false
    var percent = 0
    var onAC = true
    var charging = false
    var charged = false
    /// macOS's own estimates, in minutes. nil while macOS is still calculating.
    var timeToEmpty: Double?
    var timeToFull: Double?
    /// Energy left in the battery, in watt-hours.
    var remainingWh: Double = 0
    /// Instantaneous whole-machine draw, in watts.
    var systemWatts: Double?
    /// Running totals the battery keeps; diffing them gives a steadier average than one reading.
    var loadAccumulator: Double?
    var loadSamples: Double?
}

enum BatteryReader {
    static func read() -> BatterySnapshot {
        var snap = BatterySnapshot()

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                snap.hasBattery = true
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                snap.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
                snap.onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                snap.charging = d[kIOPSIsChargingKey] as? Bool ?? false
                snap.charged = d[kIOPSIsChargedKey] as? Bool ?? (snap.onAC && snap.percent >= 100)
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0, !snap.onAC { snap.timeToEmpty = Double(t) }
                if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0, snap.charging { snap.timeToFull = Double(t) }
            }
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return snap }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return snap }

        let millivolts = number(d["Voltage"]) ?? 0
        let batteryData = d["BatteryData"] as? [String: Any] ?? [:]
        let mAh = number(d["AppleRawCurrentCapacity"])
            ?? number(batteryData["AppleRawCurrentCapacity"])
            ?? number(batteryData["RemainingCapacity"]) ?? 0
        snap.remainingWh = mAh * millivolts / 1e6

        if let telemetry = d["PowerTelemetryData"] as? [String: Any] {
            if let load = number(telemetry["SystemLoad"]), load > 0 { snap.systemWatts = load / 1000 }
            snap.loadAccumulator = number(telemetry["AccumulatedSystemLoad"])
            snap.loadSamples = number(telemetry["SystemLoadAccumulatorCount"])
        }
        if snap.systemWatts == nil,
           let amps = (d["InstantAmperage"] ?? d["Amperage"]) as? NSNumber, amps.int64Value < 0 {
            snap.systemWatts = Double(-amps.int64Value) * millivolts / 1e6
        }
        return snap
    }

    private static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
}

/// Asks an app to quit exactly like ⌘Q does: a "quit" Apple event that goes through
/// the app's normal shutdown, so it saves state and doesn't think it crashed.
/// `NSRunningApplication.terminate()` can kill apps that opt into sudden
/// termination outright, which is what made some apps report a crash.
enum Quitter {
    static func quit(pid: pid_t) {
        DispatchQueue.global(qos: .userInitiated).async {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            do {
                _ = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 60)
            } catch let error as NSError {
                // -1743/-1744: not allowed to send Apple events to this app. Fall back
                // to the system quit. Other errors (the app quit before replying, or
                // it's showing a "Save changes?" sheet) mean it's handling the quit.
                if error.code == -1743 || error.code == -1744 {
                    onMainRunLoop { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
                }
            }
        }
    }
}

/// Per-app power the way Activity Monitor counts it: by coalition, the group macOS
/// puts an app and everything it launches into. That covers helpers, XPC services
/// (Safari's page processes), command-line tools started from a terminal app, and
/// GPU energy, none of which live inside the app's own bundle.
final class CoalitionSampler: @unchecked Sendable {  // only used on the sampler queue
    private typealias InfoFn = @convention(c) (UInt64, UnsafeMutableRawPointer, Int) -> Int32
    private let info: InfoFn?
    private var last: [UInt64: [UInt64]] = [:]
    private var lastTime: UInt64 = 0

    // Offsets into struct coalition_resource_usage (64-bit fields).
    private static let fields = [11, 20, 21, 40, 41, 42]  // energy, billed to me/others; gpu energy, billed to me/others

    init() {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        info = dlsym(rtldDefault, "coalition_info_resource_usage").map { unsafeBitCast($0, to: InfoFn.self) }
    }

    var available: Bool { info != nil }

    /// Watts per app key, averaged since the previous call.
    func sample(_ apps: [(key: String, pid: pid_t)]) -> (watts: [String: Double], seconds: Double) {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = lastTime == 0 ? 0 : Double(now - lastTime) / 1e9
        lastTime = now
        guard let info else { return ([:], dt) }

        var current: [UInt64: [UInt64]] = [:]
        var watts: [String: Double] = [:]
        for app in apps {
            guard let cid = Self.coalitionID(app.pid), current[cid] == nil else { continue }
            var buf = [UInt64](repeating: 0, count: 128)
            let rc = buf.withUnsafeMutableBytes { info(cid, $0.baseAddress!, $0.count) }
            guard rc == 0 else { continue }
            let values = Self.fields.map { buf[$0] }
            current[cid] = values

            guard dt > 0, let old = last[cid] else { continue }
            let d = zip(values, old).map { Double(Int64(bitPattern: $0 &- $1)) }
            let cpu = max(0, d[0] + d[1] - d[2])
            let gpu = max(0, d[3] + d[4] - d[5])
            let w = (cpu + gpu) / 1e9 / dt
            if w.isFinite, w < 300 { watts[app.key] = w }
        }
        last = current
        return (watts, dt)
    }

    private static func coalitionID(_ pid: pid_t) -> UInt64? {
        var ids = [UInt64](repeating: 0, count: 5)   // struct proc_pidcoalitioninfo
        let size = Int32(ids.count * MemoryLayout<UInt64>.size)
        let rc = ids.withUnsafeMutableBytes { proc_pidinfo(pid, 20 /* PROC_PIDCOALITIONINFO */, 0, $0.baseAddress, size) }
        return rc > 0 && ids[0] != 0 ? ids[0] : nil
    }
}

/// Low Power Mode needs root to change. The first time, Drain asks for your
/// password once and installs a sudoers rule that allows exactly two commands,
/// `pmset -a lowpowermode 0` and `pmset -a lowpowermode 1`, for you only.
/// After that, switching is instant with no prompt.
enum LowPowerMode {
    static let rulePath = "/etc/sudoers.d/drain-lowpowermode"

    /// Without a password, using the installed rule. False if the rule isn't there.
    static func setQuietly(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Asks for your password once, installs the rule, and sets the mode. Main thread only.
    static func installRuleAndSet(_ on: Bool) -> Bool {
        let value = on ? "1" : "0"
        let user = NSUserName()
        var script = "/usr/bin/pmset -a lowpowermode \(value)"
        if user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil {
            let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"
            script = """
            t=$(/usr/bin/mktemp) && /bin/echo '\(rule)' > "$t" && /usr/sbin/visudo -cqf "$t" \
            && /usr/sbin/chown root:wheel "$t" && /bin/chmod 0440 "$t" && /bin/mv "$t" \(rulePath); \
            /usr/bin/pmset -a lowpowermode \(value)
            """
        }
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&error)
        return error == nil
    }
}
