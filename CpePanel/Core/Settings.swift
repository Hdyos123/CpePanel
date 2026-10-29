import Foundation
import Security

/// 连接设置（密码存 Keychain，不落 UserDefaults）
struct Settings {
    var host: String
    var user: String
    var password: String

    private static let kHost = "cpe.host"
    private static let kUser = "cpe.user"
    private static let kPassKey = "cpe.password"

    static func load() -> Settings {
        let d = UserDefaults.standard
        return Settings(
            host: d.string(forKey: kHost) ?? "192.168.8.1",
            user: d.string(forKey: kUser) ?? "superadmin",
            password: Keychain.read(kPassKey) ?? ""
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: Self.kHost)
        d.set(user, forKey: Self.kUser)
        Keychain.write(Self.kPassKey, password)
    }

    static func clearPassword() {
        Keychain.delete(kPassKey)
    }

    var isConfigured: Bool { !password.isEmpty }
}

enum Keychain {
    static func write(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
