import Foundation

/// App 从 Session（app.session.mac）改名为 Now（app.now.mac）后，UserDefaults 换了域。
/// 首次以新 bundle id 启动时把旧域的设置、计时状态、后端地址整体搬过来；只做一次。
enum LegacyDefaults {
    static let oldDomain = "app.session.mac"
    private static let doneKey = "migratedFromSession"

    static func migrate(defaults: UserDefaults = .standard) {
        // 只在打包后的 Now.app 里搬；swift run 没有 bundle id，不碰。
        guard Bundle.main.bundleIdentifier == "app.now.mac", !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = UserDefaults.standard.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
