import Foundation
import Security

/// 通用密码项（kSecClassGenericPassword）的薄封装；service 固定为 "session"。
enum KeychainStore {
    static let service = "session"
    static let tokenAccount = "api-token"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String = tokenAccount) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String = tokenAccount) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String = tokenAccount) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// 后端连接配置：URL 存 UserDefaults，Token 存 Keychain；环境变量优先（开发覆盖）。
enum ConnectionConfig {
    static let urlKey = "apiBaseURL"
    static let defaultURL = "http://localhost:8787"

    static func baseURLString(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        env["SESSION_API_URL"] ?? UserDefaults.standard.string(forKey: urlKey) ?? defaultURL
    }

    static func token(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let t = env["SESSION_API_TOKEN"], !t.isEmpty { return t }
        return KeychainStore.read()
    }
}
