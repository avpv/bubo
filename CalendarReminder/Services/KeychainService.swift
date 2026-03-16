import Foundation
import Security

enum KeychainService {
    private static let serviceName = "com.reminder.yandex-calendar"

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
    }

    static func load(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        for key in [Key.yandexLogin, .yandexAppPassword, .oauthAccessToken, .oauthRefreshToken, .oauthTokenExpiry, .googleAccessToken, .googleRefreshToken, .googleTokenExpiry] {
            delete(key)
        }
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
