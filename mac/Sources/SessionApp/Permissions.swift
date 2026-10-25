import ApplicationServices
import AppKit
import UserNotifications

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的"辅助功能"授权提示（每次启动最多触发一次）。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case automation = "Privacy_Automation"
        case notifications = "Notifications"

        var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }

    static func openSettings(_ pane: Pane) {
        if pane == .notifications {
            // 通知设置不在 security 面板下。
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        } else {
            NSWorkspace.shared.open(pane.url)
        }
    }
}

enum NotificationState: Equatable {
    case unavailable   // 非 .app 形态（无 bundle id），不能调用通知 API
    case granted
    case missing
}

/// 权限状态：设置页与首次启动引导共用；App 变为前台时刷新。
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var accessibility = Permissions.accessibilityGranted
    @Published private(set) var notifications: NotificationState = .unavailable
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        Task { await refresh() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh() async {
        accessibility = Permissions.accessibilityGranted
        // 无 bundle 时 UNUserNotificationCenter.current() 会崩溃，必须先判断。
        guard Bundle.main.bundleIdentifier != nil else { notifications = .unavailable; return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notifications = (status == .authorized || status == .provisional) ? .granted : .missing
    }
}
