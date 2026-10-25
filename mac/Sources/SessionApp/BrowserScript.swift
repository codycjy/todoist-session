import AppKit
import SessionCore

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
        let script = NSAppleScript(source: "tell application \"\(spec.appName.appleScriptEscaped)\" to return URL of \(spec.tab)")
        var error: NSDictionary?
        let out = script?.executeAndReturnError(&error).stringValue
        if let error {
            // -1743 = 未授权自动化（系统设置 → 隐私与安全性 → 自动化）；-600 = 应用未运行
            Log.info("读取 \(spec.appName) URL 失败：\(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
            return nil
        }
        let url = out.flatMap { URL(string: $0) }
        Log.debug("\(spec.appName) 当前 URL 主机：\(Log.host(url))")
        return url
    }

    /// 是否有过成功的重定向；没有则 restoreAll 完全跳过（不跑 AppleScript，不触发自动化授权弹窗）。
    private static let didRedirectKey = "didRedirectTab"
    static var didRedirectTab: Bool {
        get { UserDefaults.standard.bool(forKey: didRedirectKey) }
        set { UserDefaults.standard.set(newValue, forKey: didRedirectKey) }
    }

    /// 把所有仍停在拦截页的标签页还原为原始 URL。只处理已在运行的浏览器（避免 AppleScript 把它拉起来）。
    /// 在 session 结束 / 放弃 / App 退出 / App 启动时调用。返回还原的标签页数。
    @discardableResult
    static func restoreAll() -> Int {
        guard didRedirectTab else { return 0 }
        var restored = 0
        var incomplete = false   // 有浏览器没扫成功，或有标签页没还原成功：保留标记，下次再试
        for (bundleId, spec) in specs where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            let list = """
            tell application "\(spec.appName.appleScriptEscaped)"
              set out to ""
              set wi to 0
              repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                  set ti to ti + 1
                  try
                    set u to URL of t
                    if u is not missing value then
                      if u starts with "file:" then set out to out & wi & "\t" & ti & "\t" & u & linefeed
                    end if
                  end try
                end repeat
              end repeat
              return out
            end tell
            """
            var error: NSDictionary?
            guard let out = NSAppleScript(source: list)?.executeAndReturnError(&error).stringValue, error == nil else {
                if let error { Log.info("扫描 \(spec.appName) 标签页失败：\(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")") }
                incomplete = true
                continue
            }
            for line in out.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard f.count == 3, let w = Int(f[0]), let t = Int(f[1]), let original = BlockPage.originalURL(from: f[2]) else { continue }
                let set = "tell application \"\(spec.appName.appleScriptEscaped)\" to set URL of tab \(t) of window \(w) to \"\(original.absoluteString.appleScriptEscaped)\""
                var e: NSDictionary?
                _ = NSAppleScript(source: set)?.executeAndReturnError(&e)
                if let e { Log.info("还原 \(spec.appName) 标签页失败：\(e[NSAppleScript.errorMessage] ?? "?")") } else { restored += 1 }
                if e != nil { incomplete = true }
            }
        }
        if !incomplete { didRedirectTab = false }
        if restored > 0 { Log.info("已还原 \(restored) 个被拦截的标签页") }
        return restored
    }

    @discardableResult
    static func redirect(bundleId: String, to url: URL) -> Bool {
        // 只重定向到自己的拦截页，且其中编码的原始 URL 必须是 http(s)，保证之后能安全还原。
        guard BlockPageLink.originalURL(fromTabURL: url.absoluteString) != nil else { Log.info("重定向跳过：目标不是带有效原始 URL 的拦截页"); return false }
        guard let spec = specs[bundleId] else { Log.info("重定向失败：\(bundleId) 不在受支持浏览器列表"); return false }
        let src = "tell application \"\(spec.appName.appleScriptEscaped)\" to set URL of \(spec.tab) to \"\(url.absoluteString.appleScriptEscaped)\""
        var error: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&error)
        if let error {
            Log.info("重定向 \(spec.appName) 失败：\(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
            return false
        }
        didRedirectTab = true
        Log.info("已重定向 \(spec.appName) 当前标签页（\(Log.host(BlockPageLink.originalURL(fromTabURL: url.absoluteString)))）")
        return true
    }
}
