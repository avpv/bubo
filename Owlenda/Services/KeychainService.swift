import Foundation
import Security

enum KeychainService {
    private static let serviceName = "com.reminder.yandex-calendar"

    /// Cooldown after user denies keychain access (5 minutes)
    private static let denialCooldown: TimeInterval = 300

    enum Key: String {
        case yandexLogin = "yandex_login"
        case yandexAppPassword = "yandex_app_password"
        case oauthAccessToken = "oauth_access_token"
        case oauthRefreshToken = "oauth_refresh_token"
        case oauthTokenExpiry = "oauth_token_expiry"
        // Google
        case googleAccessToken = "google_access_token"
        case googleRefreshToken = "google_refresh_token"
        case googleTokenExpiry = "google_token_expiry"
    }

    // MARK: - In-memory cache

    /// Sentinel to distinguish "we cached nil" from "not cached yet"
    private enum CacheEntry {
        case value(String)
        case missing
    }

    private static var cache: [Key: CacheEntry] = [:]
    /// Timestamp when the user last denied keychain access
    private static var lastDenialDate: Date?

    /// Whether keychain access is currently blocked due to user denial cooldown
    private static var isDenied: Bool {
        guard let denial = lastDenialDate else { return false }
        return Date().timeIntervalSince(denial) < denialCooldown
    }

    static func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }

        // Update cache on successful save
        cache[key] = .value(value)
        // Successful keychain operation clears any denial state
        lastDenialDate = nil
    }

    static func load(_ key: Key) -> String? {
        // Return cached value if available
        if let entry = cache[key] {
            switch entry {
            case .value(let str): return str
            case .missing: return nil
            }
        }

        // If user recently denied keychain access, don't prompt again
        if isDenied {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // errSecUserCanceled (-128): user clicked "Deny" on the keychain dialog
        // errSecAuthFailed (-25293): authentication failed (wrong password or denied)
        if status == errSecUserCanceled || status == errSecAuthFailed {
            lastDenialDate = Date()
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            cache[key] = .missing
            return nil
        }

        let value = String(data: data, encoding: .utf8)
        if let value {
            cache[key] = .value(value)
        } else {
            cache[key] = .missing
        }
        return value
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        cache[key] = .missing
    }

    static func deleteAll() {
        for key in [Key.yandexLogin, .yandexAppPassword, .oauthAccessToken, .oauthRefreshToken, .oauthTokenExpiry, .googleAccessToken, .googleRefreshToken, .googleTokenExpiry] {
            delete(key)
        }
    }

    /// Clear the in-memory cache, forcing the next load to hit the keychain.
    /// Call this when the user explicitly grants access (e.g. "Always Allow").
    static func clearCache() {
        cache.removeAll()
        lastDenialDate = nil
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save error: \(status)"
        }
    }
}
