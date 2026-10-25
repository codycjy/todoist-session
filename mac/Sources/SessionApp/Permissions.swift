import ApplicationServices
import AppKit

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的"辅助功能"授权提示（每次启动最多触发一次）。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
