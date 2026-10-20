import Foundation
import Security
import LocalAuthentication
import MemebooruCore

/// Persists the x.com session in the Keychain (per device; never inside the synced collection).
/// The item is protected by biometrics: reads prompt Touch ID (with device-password fallback via
/// `.userPresence`) instead of the keychain password.
enum XKeychain {
    private static let service = "dev.mrmacduckinson.memebooru.x"
    private static let account = "session"

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ session: XSession) {
        let data = (try? JSONEncoder().encode(session)) ?? Data()
        SecItemDelete(base() as CFDictionary)
        var add = base()
        add[kSecValueData as String] = data
        // Touch ID (or device passcode) required to read; this device only, never synced.
        if let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                    .userPresence, nil) {
            add[kSecAttrAccessControl as String] = ac
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Reads the session, prompting Touch ID. Returns nil if the item is absent or the user cancels.
    static func load(reason: String = "Разблокировать сеанс x.com") -> XSession? {
        let ctx = LAContext()
        ctx.localizedReason = reason
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = ctx
        query[kSecUseOperationPrompt as String] = reason
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(XSession.self, from: data)
    }

    static func clear() { SecItemDelete(base() as CFDictionary) }
}

/// Discovered x.com query ids (not sensitive) — kept in UserDefaults.
enum XEndpointDefaults {
    private static let key = "x.endpointOverride"
    static func load() -> XEndpointOverride? {
        AppDefaults.store.data(forKey: key).flatMap { try? JSONDecoder().decode(XEndpointOverride.self, from: $0) }
    }
    static func save(_ o: XEndpointOverride) {
        var merged = load() ?? XEndpointOverride()
        if let v = o.likes { merged.likes = v }
        if let v = o.bookmarks { merged.bookmarks = v }
        if let v = o.userByScreenName { merged.userByScreenName = v }
        merged.updatedAt = o.updatedAt
        if let d = try? JSONEncoder().encode(merged) { AppDefaults.store.set(d, forKey: key) }
    }
    static func endpoints() -> XEndpoints {
        var e = XEndpoints.standard()
        if let o = load() { e.apply(o) }
        return e
    }
}
