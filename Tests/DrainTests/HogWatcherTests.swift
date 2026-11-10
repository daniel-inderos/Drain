import Foundation
import Testing
@testable import Drain

@Suite struct HogWatcherTests {
    let chrome = PowerHog(id: "chrome", watts: 5, gainMinutes: 40)

    /// Feeds one reading every `step` seconds for `span` seconds; returns the first warning and when.
    private func run(_ w: inout HogWatcher, from start: Double = 0, span: Double, step: Double = 30,
                     system: Double = 12, onBattery: Bool = true, menuOpen: Bool = false,
                     apps: [PowerHog]? = nil) -> (id: String, at: Double)? {
        var t = start
        while t <= start + span {
            if let id = w.observe(at: t, onBattery: onBattery, menuOpen: menuOpen,
                                  systemWatts: system, apps: apps ?? [chrome]) { return (id, t) }
            t += step
        }
        return nil
    }

    @Test func warnsOnceSustainedAtSlowSampling() throws {
        var w = HogWatcher()
        let hit = try #require(run(&w, span: 600))
        #expect(hit.id == "chrome")
        #expect(hit.at == 300)
    }

    @Test func warnsAtFastSamplingToo() throws {
        var w = HogWatcher()
        let hit = try #require(run(&w, span: 600, step: 2))
        #expect(hit.at == 300)
    }

    @Test func notBeforeFiveMinutes() {
        var w = HogWatcher()
        #expect(run(&w, span: 290) == nil)
    }

    @Test func aSpikeDoesNotCount() {
        var w = HogWatcher()
        #expect(run(&w, span: 240) == nil)
        // Drops below the share for one reading, then comes back: the clock restarts.
        #expect(w.observe(at: 270, onBattery: true, menuOpen: false, systemWatts: 12,
                          apps: [PowerHog(id: "chrome", watts: 1, gainMinutes: 5)]) == nil)
        #expect(run(&w, from: 300, span: 240) == nil)
    }

    @Test func smallShareOrSmallDrawOrSmallGainNeverWarns() {
        var a = HogWatcher()
        #expect(run(&a, span: 1200, system: 30) == nil)   // 5 of 30 W is under 30%
        var b = HogWatcher()
        #expect(run(&b, span: 1200, system: 6, apps: [PowerHog(id: "x", watts: 2, gainMinutes: 40)]) == nil)
        var c = HogWatcher()
        #expect(run(&c, span: 1200, apps: [PowerHog(id: "x", watts: 5, gainMinutes: 10)]) == nil)
    }

    @Test func aGapBreaksTheRun() {
        var w = HogWatcher()
        #expect(run(&w, span: 240) == nil)
        // The Mac slept: nothing was seen for ten minutes.
        #expect(run(&w, from: 840, span: 240) == nil)
        #expect(run(&w, from: 1080, span: 120) != nil)
    }

    @Test func notAgainForHoursThenAgain() throws {
        var w = HogWatcher()
        _ = try #require(run(&w, span: 300))
        #expect(run(&w, from: 330, span: 3 * 3600) == nil)
        #expect(run(&w, from: 330 + 3 * 3600 + 30, span: 3600) != nil)
    }

    @Test func pluggedInResetsTheRunButNotTheMemory() throws {
        var w = HogWatcher()
        #expect(run(&w, span: 240) == nil)
        #expect(run(&w, from: 270, span: 600, onBattery: false) == nil)
        #expect(run(&w, from: 900, span: 240) == nil)       // must start over
        _ = try #require(run(&w, from: 1140, span: 120))    // warned
        _ = run(&w, from: 1300, span: 60, onBattery: false)
        #expect(run(&w, from: 1400, span: 1000) == nil)     // same app, still cooling down
    }

    @Test func silentWhileMenuOpenAndRestartsAfter() throws {
        var w = HogWatcher()
        #expect(run(&w, span: 600, step: 2, menuOpen: true) == nil)
        #expect(run(&w, from: 602, span: 290) == nil)
        _ = try #require(run(&w, from: 892, span: 30))
    }

    @Test func namesTheBiggestWhenTwoQualify() throws {
        var w = HogWatcher()
        let apps = [PowerHog(id: "a", watts: 4, gainMinutes: 30), PowerHog(id: "b", watts: 6, gainMinutes: 50)]
        let hit = try #require(run(&w, span: 300, system: 12, apps: apps))
        #expect(hit.id == "b")
    }

    @Test func messageWording() {
        #expect(Format.hogMessage(name: "Chrome", share: 0.34, gainMinutes: 41)
            == "Chrome is using about a third of your battery power. Quitting it would add about 40 minutes.")
        #expect(Format.shareOf(0.5) == "about half of")
        #expect(Format.shareOf(0.42) == "about 40% of")
        #expect(Format.approxDuration(70) == "1 hour 10 minutes")
        #expect(Format.approxDuration(120) == "2 hours")
        #expect(Format.approxDuration(4) == "4 minutes")
    }

    @Test func settingsDefaultOffAndPersist() throws {
        let name = "drain.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let s = DrainSettings(defaults: defaults)
        #expect(!s.showTimeLeft && !s.warnAboutHogs && s.ignoredApps.isEmpty)
        s.showTimeLeft = true
        s.ignoredApps = ["com.x": "X"]
        let again = DrainSettings(defaults: defaults)
        #expect(again.showTimeLeft && !again.warnAboutHogs && again.ignoredApps == ["com.x": "X"])
    }
}
