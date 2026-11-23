import Foundation
import Security

/// Small wrapper over generic-password Keychain items.
enum Keychain {
    private static let service = "com.sidebyrner.planner"

    static func read(account: String, group: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value`, or deletes the item when it is nil. Returns false if the Keychain refused (e.g. no entitlement for `group`).
    @discardableResult
    static func write(_ value: String?, account: String, group: String? = nil) -> Bool {
        var match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { match[kSecAttrAccessGroup as String] = group }
        SecItemDelete(match as CFDictionary)
        guard let value else { return true }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// The server address and device token, readable by the app, its intents and (on iOS) the widget.
///
/// On iOS both live in a Keychain group shared with the widget extension. If that group isn't
/// available (an unsigned simulator build, or signing without the entitlement), it falls back to
/// the app's own Keychain, which is where earlier versions kept the token.
enum SharedCredentials {
    private static let tokenAccount = "deviceToken"
    private static let serverAccount = "serverURL"

    /// "$(AppIdentifierPrefix)com.sidebyrner.planner.shared", filled in from Info.plist at build time.
    static var group: String? {
        #if os(iOS)
        let value = Bundle.main.object(forInfoDictionaryKey: "PlannerKeychainGroup") as? String
        return value?.isEmpty == false && value?.hasPrefix("$(") == false ? value : nil
        #else
        return nil
        #endif
    }

    static var token: String? {
        get { read(tokenAccount) }
        set { write(newValue, tokenAccount) }
    }

    static var serverURL: String? {
        get { read(serverAccount) ?? UserDefaults.standard.string(forKey: "serverURL") }
        set { write(newValue, serverAccount) }
    }

    private static func read(_ account: String) -> String? {
        if let group, let shared = Keychain.read(account: account, group: group) { return shared }
        let legacy = Keychain.read(account: account)
        // Move an item saved before the shared group existed, so the widget can see it too.
        if let legacy, let group, Keychain.write(legacy, account: account, group: group) {
            Keychain.write(nil, account: account)
        }
        return legacy
    }

    private static func write(_ value: String?, _ account: String) {
        let stored = value?.isEmpty == false ? value : nil
        if let group, Keychain.write(stored, account: account, group: group) {
            Keychain.write(nil, account: account)
            return
        }
        Keychain.write(stored, account: account)
    }
}
