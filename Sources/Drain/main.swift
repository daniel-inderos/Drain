import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DrainModel()
        let drag = DragController(model: model)
        status = StatusController(model: model, drag: drag)
        model.start()
        registerLoginItem()
    }

    /// Opens Drain at login. Done once, so if you turn it off in System Settings
    /// › General › Login Items, Drain leaves it off.
    private func registerLoginItem() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
            NSLog("Drain: login item registered (\(SMAppService.mainApp.status.rawValue))")
        } catch {
            NSLog("Drain: couldn't register login item: \(error)")
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
