import AppKit

/// "Quit an App to Save Power": a submenu with every app the model lists, the
/// pill's slices first, then the ones that didn't fit. Native items, so arrow
/// keys, type-to-select and VoiceOver work. Choosing one quits that app.
///
/// While the submenu is open it is only ever updated in place: titles and
/// numbers change, items are never moved or removed, and new apps are appended.
/// So the row under the pointer or the keyboard highlight cannot jump. An app
/// that disappears meanwhile (quit, or it dropped below the list's threshold)
/// stays as a dimmed row until the submenu is opened again, and comes back to
/// life if it returns (a quit that was refused). Closed, it is simply rebuilt.
@MainActor
final class QuitAppsMenu: NSObject, NSMenuDelegate {
    let item: NSMenuItem
    private let submenu = NSMenu()
    private let model: DrainModel
    private var rows: [String: NSMenuItem] = [:]   // by app id
    private var isOpen = false

    init(model: DrainModel) {
        self.model = model
        item = NSMenuItem(title: "Quit an App to Save Power", action: nil, keyEquivalent: "")
        super.init()
        submenu.autoenablesItems = false
        submenu.delegate = self
        item.submenu = submenu
        refresh()
    }

    private var apps: [AppDrain] { model.apps + model.otherApps }

    /// Call after the model changes.
    func refresh() {
        let list = apps
        if isOpen {
            update(in: list)
        } else {
            item.isHidden = list.isEmpty   // no empty section
            rebuild(list)
        }
    }

    private func rebuild(_ list: [AppDrain]) {
        submenu.removeAllItems()
        rows = [:]
        for app in list { append(app) }
    }

    private func update(in list: [AppDrain]) {
        for app in list {
            if let row = rows[app.id] { configure(row, app) } else { append(app) }
        }
        let live = Set(list.map(\.id))
        for (id, row) in rows where !live.contains(id) {
            row.isEnabled = false
            row.badge = nil
        }
    }

    private func append(_ app: AppDrain) {
        let row = NSMenuItem(title: "Quit \(app.name)", action: #selector(quit(_:)), keyEquivalent: "")
        row.target = self
        row.representedObject = app.id
        // A copy, so sizing it doesn't shrink the icon the pill uses.
        if let icon = app.icon.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            row.image = icon
        }
        configure(row, app)
        submenu.addItem(row)
        rows[app.id] = row
    }

    private func configure(_ row: NSMenuItem, _ app: AppDrain) {
        row.isEnabled = true
        let detail = app.hasEstimate && app.gainMinutes >= 0.05 ? Format.gain(app.gainMinutes) : Format.watts(app.watts)
        if row.badge?.stringValue != detail { row.badge = NSMenuItemBadge(string: detail) }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let app = apps.first(where: { $0.id == id }) else { return }
        model.quit(app)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(apps)   // fresh order each time it opens
        isOpen = true
    }

    // No rebuild here: the chosen item's action can still be on its way, and its
    // row has to outlive this call. The next model change or open rebuilds.
    func menuDidClose(_ menu: NSMenu) { isOpen = false }
}

extension AppDrain {
    /// For VoiceOver: "Safari, using 1.2 watts".
    var spokenSummary: String {
        let w = watts < 0.05 ? "less than 0.1 watts" : String(format: "%.1f watts", watts)
        return "\(name), using \(w)"
    }

    /// "Quitting it wins back about 1 hour 10 minutes"; empty without an estimate.
    var spokenGain: String {
        guard hasEstimate, gainMinutes >= 0.05 else { return "" }
        let m = Int(gainMinutes.rounded())
        if gainMinutes < 1 { return "Quitting it wins back under a minute" }
        let h = m / 60, rest = m % 60
        var parts: [String] = []
        if h > 0 { parts.append(h == 1 ? "1 hour" : "\(h) hours") }
        if rest > 0 || h == 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return "Quitting it wins back about " + parts.joined(separator: " ")
    }
}
