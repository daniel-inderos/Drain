import Foundation
import UserNotifications

/// Local notifications for the power-hungry app warning.
///
/// `UNUserNotificationCenter.current()` raises an Objective-C exception when the
/// process isn't an app bundle (a bare binary run from .build/), which Swift can't
/// catch. So every entry point checks `available` first; without it nothing
/// happens and the answer is "no".
final class HogNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = HogNotifier()

    /// True only inside a real .app with a bundle identifier.
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? {
        guard Self.available else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    /// Asks for permission; call only when the user has just turned the option on.
    /// `done` runs on the main run loop.
    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else { onMainRunLoop { done(false) }; return }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            onMainRunLoop { done(granted) }
        }
    }

    /// Whether notifications are still allowed, without ever prompting.
    func checkStillAllowed(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else { onMainRunLoop { done(false) }; return }
        center.getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            onMainRunLoop { done(ok) }
        }
    }

    func post(title: String, body: String, id: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { debugLog("notification failed: \(error)") }
        }
    }

    // Drain is a menu bar app and can count as frontmost; show the banner anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner])
    }
}
