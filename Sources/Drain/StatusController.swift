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

        let settings = NSMenuItem(title: "Battery Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        settings.keyEquivalentModifierMask = []
        menu.addItem(settings)

        // Hold Option to swap it for Quit, like other menu bar extras.
        let quit = NSMenuItem(title: "Quit Drain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.keyEquivalentModifierMask = [.option]
        quit.isAlternate = true
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.menuOpen = true
        if let header { header.frame.size = header.fittingSize }
        syncSwitch()
    }

    func menuDidClose(_ menu: NSMenu) {
        model.menuClosed()
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
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
