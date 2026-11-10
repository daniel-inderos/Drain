import AppKit
import Combine
import SwiftUI

/// The menu bar item and its menu. The menu is a real NSMenu, so it gets the
/// system's own glass, corners, shadow, open/close animation and row highlight.
/// The battery lives in it as a custom view; the rest are ordinary menu items.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: DrainModel
    private let drag: DragController
    private let menu = NSMenu()
    private var header: NSHostingView<MenuView>?
    private var lowPowerRow: LowPowerRowView?
    private var quitApps: QuitAppsMenu?
    private var removeRuleItem: NSMenuItem?
    private var removingRule = false
    private var subscription: AnyCancellable?
    private var iconKey = ""

    init(model: DrainModel, drag: DragController) {
        self.model = model
        self.drag = drag
        super.init()

        item.button?.imagePosition = .imageOnly
        buildMenu()
        item.menu = menu

        drag.closeMenu = { [weak self] in self?.menu.cancelTracking() }
        // The one-time password prompt can't sit under an open menu.
        model.modalHook = { [weak self] active in if active { self?.menu.cancelTracking() } }

        // objectWillChange fires before the value changes; look once it has.
        subscription = model.objectWillChange
            .sink { [weak self] _ in
                onMainRunLoop {
                    self?.refreshButton()
                    self?.syncSwitch()
                    self?.quitApps?.refresh()
                }
            }
        refreshButton()

        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                self?.item.button?.performClick(nil)
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        let host = NSHostingView(rootView: MenuView(model: model, drag: drag))
        host.frame.size = host.fittingSize
        header = host
        let headerItem = NSMenuItem()
        headerItem.view = host
        menu.addItem(headerItem)

        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Energy Mode"))
        let row = LowPowerRowView(width: host.frame.width)
        row.onToggle = { [weak self] in
            guard let self else { return }
            self.model.setLowPower(!self.model.lowPower)
            row.isOn = self.model.lowPower
        }
        lowPowerRow = row
        let lowPowerItem = NSMenuItem()
        lowPowerItem.view = row
        menu.addItem(lowPowerItem)

        menu.addItem(.separator())

        // Quitting any app, not just the ones with a slice. Hidden when there are none.
        let quitApps = QuitAppsMenu(model: model)
        self.quitApps = quitApps
        menu.addItem(quitApps.item)

        let settings = NSMenuItem(title: "Battery Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        settings.keyEquivalentModifierMask = []
        menu.addItem(settings)

        // Hold Option to swap it for Quit, like other menu bar extras.
        let quit = NSMenuItem(title: "Quit Drain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.keyEquivalentModifierMask = [.option]
        quit.isAlternate = true
        menu.addItem(quit)

        // Option+Shift: take back the Low Power permission. Only offered while the rule exists.
        let remove = NSMenuItem(title: "Remove Low Power Mode Permission…",
                                action: #selector(removeLowPowerRule), keyEquivalent: "")
        remove.target = self
        remove.keyEquivalentModifierMask = [.option, .shift]
        remove.isAlternate = true
        remove.isHidden = !LowPowerMode.ruleInstalled
        removeRuleItem = remove
        menu.addItem(remove)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Submenus report to their own delegates; this one only owns the main menu.
        guard menu === self.menu else { return }
        drag.clearHint()
        removeRuleItem?.isHidden = !LowPowerMode.ruleInstalled
        quitApps?.refresh()
        model.menuOpen = true
        if let header { header.frame.size = header.fittingSize }
        syncSwitch()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        drag.clearHint()
        model.menuClosed()
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The menu is already closed by the time a chosen item runs; the hook says so
    /// again for safety, then the password prompt gets a moment to have the screen.
    @objc private func removeLowPowerRule() {
        guard !removingRule else { return }
        removingRule = true
        model.modalHook?(true)
        onMainRunLoop(after: 0.35) { [weak self] in
            // Cancelling the prompt or a failed delete both come back false; neither
            // is reported as success, and the item stays offered while the file exists.
            if !LowPowerMode.removeRule() { debugLog("sudoers rule not removed") }
            self?.removingRule = false
            self?.removeRuleItem?.isHidden = !LowPowerMode.ruleInstalled
            self?.model.modalHook?(false)
        }
    }

    private func syncSwitch() {
        lowPowerRow?.isOn = model.lowPower
    }

    // MARK: - Icon

    private func refreshButton() {
        guard let button = item.button else { return }
        let key = "\(model.percent)|\(model.state)|\(model.lowPower)"
        guard key != iconKey else { return }
        iconKey = key
        button.image = BatteryIcon.image(
            percent: model.state == .noBattery ? 100 : model.percent,
            pluggedIn: model.state.onAC, lowPower: model.lowPower)
        button.setAccessibilityLabel("Battery \(model.percent) percent")
    }
}
