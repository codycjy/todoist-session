import Foundation
import UserNotifications

/// 专注结束的本地通知。无 bundle（`swift run`）时是 no-op，因为此时调用
/// `UNUserNotificationCenter.current()` 会崩溃。权限被拒绝时静默跳过。
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func focusCompleted(title: String) {
        guard isAvailable else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:   // 首次才请求
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            case .authorized, .provisional: break
            default: return
            }
            let content = UNMutableNotificationContent()
            content.title = "专注完成：\(title)，休息一下"
            content.sound = .default
            let request = UNNotificationRequest(identifier: "focus-complete-\(UUID().uuidString)",
                                                content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
