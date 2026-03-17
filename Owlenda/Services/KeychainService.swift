import Foundation
import Security

enum KeychainService {
    private static let serviceName = "com.reminder.yandex-calendar"

    enum Key: String, CaseIterable {
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

    private static var cache: [Key: String] = [:]
    private static var cacheLoaded = false

    /// True when the user denied keychain access via the macOS dialog.
    /// UI should check this to show an actionable message.
    private(set) static var isAccessDenied = false

    // MARK: - Public API

    static func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)

        // Delete then add (both in Data Protection keychain)
        let baseQuery = self.baseQuery(for: key)
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }

        cache[key] = value
        isAccessDenied = false
    }

    static func load(_ key: Key) -> String? {
        // Serve from cache if available
        if let value = cache[key] {
            return value
        }
        // If we already loaded everything and this key isn't in cache, it's absent
        if cacheLoaded {
            return nil
        }

        // Skip keychain calls if user previously denied access
        if isAccessDenied {
            return nil
        }

        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecUserCanceled || status == errSecAuthFailed {
            isAccessDenied = true
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        cache[key] = value
        return value
    }

    static func delete(_ key: Key) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        cache.removeValue(forKey: key)
    }

    static func deleteAll() {
        for key in Key.allCases {
            delete(key)
        }
    }

    /// Pre-load all keys into memory cache.
    /// Call once at app startup to avoid repeated keychain hits.
    static func warmUpCache() {
        guard !cacheLoaded else { return }
        for key in Key.allCases {
            _ = load(key)
        }
        cacheLoaded = true
    }

    /// Reset denial state (e.g. user re-authorized in Keychain Access).
    static func resetAccessDenied() {
        isAccessDenied = false
        cacheLoaded = false
        cache.removeAll()
    }

    // MARK: - Migration

    /// Migrate items from legacy keychain to Data Protection keychain.
    /// Call once at app startup before any other keychain operations.
    static func migrateFromLegacyKeychainIfNeeded() {
        let migrationKey = "KeychainMigratedToDataProtection"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        for key in Key.allCases {
            // Try reading from legacy keychain (without kSecUseDataProtectionKeychain)
            if let value = loadFromLegacy(key) {
                // Save to Data Protection keychain
                try? save(value, for: key)
                // Delete from legacy
                deleteFromLegacy(key)
            }
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    // MARK: - Private

    /// Base query using the modern Data Protection keychain — no ACL dialogs.
    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// Read from the legacy (file-based) keychain — used only for migration.
    private static func loadFromLegacy(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
            // No kSecUseDataProtectionKeychain → legacy keychain
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // If denied during migration, skip gracefully — don't block the app
        if status == errSecUserCanceled || status == errSecAuthFailed {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteFromLegacy(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save error: \(status)"
        case .accessDenied:
            return "Keychain access was denied. Open Keychain Access and allow Owlenda."
        }
    }
}
