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
        "com.vivaldi.Vivaldi": .init(appName: "Vivaldi", tab: "active tab of front window"),
    ]

    /// 返回当前标签页 URL；无权限/无窗口时返回 nil。必须在主线程调用（NSAppleScript 非线程安全）。
    static func currentURL(bundleId: String) -> URL? {
        guard let spec = specs[bundleId] else { Log.debug("非受支持浏览器，不读 URL：\(bundleId)"); return nil }
        let script = NSAppleScript(source: "tell application \"\(spec.appName)\" to return URL of \(spec.tab)")
        var error: NSDictionary?
        let out = script?.executeAndReturnError(&error).stringValue
        if let error {
            // -1743 = 未授权自动化（系统设置 → 隐私与安全性 → 自动化）；-600 = 应用未运行
            Log.info("读取 \(spec.appName) URL 失败：\(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
            return nil
        }
        Log.debug("\(spec.appName) 当前 URL：\(out ?? "nil")")
        return out.flatMap { URL(string: $0) }
    }

    @discardableResult
    static func redirect(bundleId: String, to url: URL) -> Bool {
        guard let spec = specs[bundleId] else { Log.info("重定向失败：\(bundleId) 不在受支持浏览器列表"); return false }
        let src = "tell application \"\(spec.appName)\" to set URL of \(spec.tab) to \"\(url.absoluteString)\""
        var error: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&error)
        if let error {
            Log.info("重定向 \(spec.appName) 失败：\(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
            return false
        }
        Log.info("已重定向 \(spec.appName) 当前标签页 → \(url.absoluteString)")
        return true
    }
}
