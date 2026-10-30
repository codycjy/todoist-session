import Foundation
import UserNotifications

/// 通知上的按钮。
enum NotificationAction: String {
    /// 休息结束：按刚才那段专注再来一段。
    case resume = "now.resume"
    /// 休息结束：开始建议的下一个 Todoist 任务（userInfo["taskId"]）。
    case next = "now.next"
}

/// 专注/休息到点的本地通知。无 bundle（`swift run`）时是 no-op，因为此时调用
/// `UNUserNotificationCenter.current()` 会崩溃。权限被拒绝时静默跳过。
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    private static let delegate = Delegate()
    private static let actionCategory = "now.actions"

    /// 启动时调用一次：接收按钮点击；App 在前台时也显示横幅。
    @MainActor static func setUp(onAction: @escaping @MainActor (NotificationAction?, [AnyHashable: Any]) -> Void) {
        guard isAvailable else { return }
        delegate.onAction = onAction
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// 还没问过就弹系统授权框；macOS 只有问过之后才会在「系统设置 → 通知」里列出本 App。
    @discardableResult
    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .authorized, .provisional: return true
        default: return false
        }
    }

    /// `actions` 是（按钮, 标题）列表；按钮标题随内容变化，所以每次发之前重新注册分类。
    static func post(_ title: String, body: String? = nil, actions: [(NotificationAction, String)] = [],
                     userInfo: [String: String] = [:]) {
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
            content.title = title
            if let body { content.body = body }
            content.sound = .default
            content.userInfo = userInfo
            if !actions.isEmpty {
                let buttons = actions.map { UNNotificationAction(identifier: $0.0.rawValue, title: $0.1, options: [.foreground]) }
                center.setNotificationCategories([UNNotificationCategory(identifier: actionCategory, actions: buttons,
                                                                         intentIdentifiers: [])])
                content.categoryIdentifier = actionCategory
            }
            let request = UNNotificationRequest(identifier: "session-\(UUID().uuidString)",
                                                content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

private final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onAction: (@MainActor (NotificationAction?, [AnyHashable: Any]) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let action = NotificationAction(rawValue: response.actionIdentifier)
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            self.onAction?(action, info)
            done()
        }
    }
}
