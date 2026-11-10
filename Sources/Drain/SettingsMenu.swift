import AppKit

/// "Settings": the three options as native checkmark items. Choosing one closes
/// the menu, so nothing here has to survive being changed while it is open:
/// the ignore list is built when its submenu opens and left alone until then.
@MainActor
final class SettingsMenu: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    private let submenu = NSMenu()
    private let ignoreMenu = NSMenu()
    private let model: DrainModel
    private let settings: DrainSettings
    private let showTimeItem: NSMenuItem
    private let warnItem: NSMenuItem
    private var names: [String: String] = [:]   // bundle id -> name, as listed
    /// Called after "Show Time Left in Menu Bar" changes.
    var onShowTimeChanged: (() -> Void)?

    init(model: DrainModel) {
        self.model = model
        settings = model.settings
        showTimeItem = NSMenuItem(title: "Show Time Left in Menu Bar", action: #selector(toggleShowTime), keyEquivalent: "")
        warnItem = NSMenuItem(title: "Warn About Power-Hungry Apps", action: #selector(toggleWarn), keyEquivalent: "")
        super.init()
        submenu.autoenablesItems = false
        for row in [showTimeItem, warnItem] {
            row.target = self
            submenu.addItem(row)
        }
        let ignore = NSMenuItem(title: "Never Suggest Quitting", action: nil, keyEquivalent: "")
        ignoreMenu.autoenablesItems = false
        ignoreMenu.delegate = self
        ignore.submenu = ignoreMenu
        submenu.addItem(.separator())
        submenu.addItem(ignore)
        item.submenu = submenu
        syncChecks()
    }

    private func syncChecks() {
        showTimeItem.state = settings.showTimeLeft ? .on : .off
        warnItem.state = settings.warnAboutHogs ? .on : .off
    }

    @objc private func toggleShowTime() {
        settings.showTimeLeft.toggle()
        syncChecks()
        onShowTimeChanged?()
    }

    /// Turning it on is the one moment macOS is asked for notification permission.
    /// It only stays on if that is granted.
    @objc private func toggleWarn() {
        guard !settings.warnAboutHogs else {
            settings.warnAboutHogs = false
            syncChecks()
            return
        }
        HogNotifier.shared.requestPermission { [weak self] granted in
            self?.settings.warnAboutHogs = granted
            self?.syncChecks()
        }
    }

    /// Launch check: if the option is on but the user has since switched
    /// notifications off in System Settings, turn it off instead of staying silent.
    func verifyStillAllowed() {
        guard settings.warnAboutHogs else { return }
        HogNotifier.shared.checkStillAllowed { [weak self] ok in
            guard !ok else { return }
            self?.settings.warnAboutHogs = false
            self?.syncChecks()
        }
    }

    // MARK: - Ignore list

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === ignoreMenu else { return }
        ignoreMenu.removeAllItems()
        names = model.ignoredApps
        var icons: [String: NSImage] = [:]
        for app in model.apps + model.otherApps {
            guard let id = app.bundleID else { continue }
            names[id] = app.name
            if let icon = app.icon.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                icons[id] = icon
            }
        }
        let sorted = names.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        if sorted.isEmpty {
            let none = NSMenuItem(title: "No Apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            ignoreMenu.addItem(none)
        }
        for (id, name) in sorted {
            let row = NSMenuItem(title: name, action: #selector(toggleIgnored(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = id
            row.image = icons[id]
            row.state = model.ignoredApps[id] != nil ? .on : .off
            ignoreMenu.addItem(row)
        }
    }

    @objc private func toggleIgnored(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setIgnored(id, name: names[id] ?? sender.title, model.ignoredApps[id] == nil)
    }
}
