import Foundation
import UserNotifications

@MainActor
final class MessageNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MessageNotifier()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notify(sender: String, body: String, messageId: String) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: messageId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
