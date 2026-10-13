import Foundation
@preconcurrency import UserNotifications

/// Posts user-visible notifications (respecting the `notificationsEnabled` setting).
///
/// Uses UNUserNotificationCenter when running from the .app bundle. Without a bundle (e.g. a bare
/// `swift run` binary, where UNUserNotificationCenter raises) or if the center refuses this ad-hoc
/// signed build, it falls back to osascript with the text passed as argv, so no message text can
/// ever be interpreted as AppleScript.
public final class UserNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = UserNotifier()
    
    private let lock = NSLock()
    private var delegateInstalled = false
    
    private var canUseNotificationCenter: Bool {
        return Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
    
    public func post(title: String, message: String) {
        guard SynapsConfig.load().notificationsEnabled else { return }
        guard canUseNotificationCenter else {
            postViaOsascript(title: title, message: message)
            return
        }
        
        let center = UNUserNotificationCenter.current()
        installDelegateIfNeeded(on: center)
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("⚠️ [UserNotifier] Notification Center unavailable (\(error.localizedDescription)); using osascript")
                self.postViaOsascript(title: title, message: message)
                return
            }
            // Not granted: the user turned Synaps notifications off in System Settings.
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error = error {
                    print("⚠️ [UserNotifier] Could not post notification: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func installDelegateIfNeeded(on center: UNUserNotificationCenter) {
        lock.lock()
        defer { lock.unlock() }
        guard !delegateInstalled else { return }
        delegateInstalled = true
        center.delegate = self
    }
    
    /// Without this, banners posted while Synaps is the frontmost app are silently dropped.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
    
    private func postViaOsascript(title: String, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
            "-e", "end run",
            "--", message, title
        ]
        try? process.run()
    }
}
