import AppKit

/// 支持的浏览器：bundle id → AppleScript 里的应用名与"当前标签页"写法。
enum Browser {
    struct Spec { let appName: String; let tab: String }   // tab 例如 "current tab of front window"
    static let specs: [String: Spec] = [
        "com.apple.Safari": .init(appName: "Safari", tab: "current tab of front window"),
        "com.google.Chrome": .init(appName: "Google Chrome", tab: "active tab of front window"),
        "company.thebrowser.Browser": .init(appName: "Arc", tab: "active tab of front window"),
        "com.microsoft.edgemac": .init(appName: "Microsoft Edge", tab: "active tab of front window"),
        "com.brave.Browser": .init(appName: "Brave Browser", tab: "active tab of front window"),
    ]

    /// 返回当前标签页 URL；无权限/无窗口时返回 nil。必须在主线程调用（NSAppleScript 非线程安全）。
    static func currentURL(bundleId: String) -> URL? {
        guard let spec = specs[bundleId] else { return nil }
        let script = NSAppleScript(source: "tell application \"\(spec.appName)\" to return URL of \(spec.tab)")
        var error: NSDictionary?
        guard let out = script?.executeAndReturnError(&error).stringValue, error == nil else { return nil }
        return URL(string: out)
    }

    @discardableResult
    static func redirect(bundleId: String, to url: URL) -> Bool {
        guard let spec = specs[bundleId] else { return false }
        let src = "tell application \"\(spec.appName)\" to set URL of \(spec.tab) to \"\(url.absoluteString)\""
        var error: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&error)
        return error == nil
    }
}
