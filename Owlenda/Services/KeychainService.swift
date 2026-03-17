import Foundation
import Security

/// Thread-safe keychain wrapper using the modern Data Protection keychain.
///
/// Data Protection keychain (`kSecUseDataProtectionKeychain`) is tied to the app's
/// entitlements (team ID + bundle ID), not to file-based ACLs. This means macOS
/// never shows the legacy "Allow / Deny" keychain dialog.
///
/// All values are cached in memory after first read. The cache is invalidated
/// on save/delete so callers always see fresh data.
enum KeychainService {
    private static let serviceName = "com.reminder.yandex-calendar"
    private static let lock = NSLock()

    enum Key: String, CaseIterable {
        case yandexLogin = "yandex_login"
        case yandexAppPassword = "yandex_app_password"
        case oauthAccessToken = "oauth_access_token"
        case oauthRefreshToken = "oauth_refresh_token"
        case oauthTokenExpiry = "oauth_token_expiry"
        case googleAccessToken = "google_access_token"
        case googleRefreshToken = "google_refresh_token"
        case googleTokenExpiry = "google_token_expiry"
    }

    // MARK: - Thread-safe state

    private static var _cache: [Key: String] = [:]
    private static var _cacheLoaded = false
    private static var _isAccessDenied = false

    /// True when the user denied keychain access via the macOS dialog.
    /// Checked by `ReminderService` to update its `@Published` property for UI.
    static var isAccessDenied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isAccessDenied
    }

    // MARK: - Public API

    static func save(_ value: String, for key: Key) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = Data(value.utf8)
        let base = baseQuery(for: key)
        SecItemDelete(base as CFDictionary)

        var addQuery = base
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }

        _cache[key] = value
        _isAccessDenied = false
    }

    static func load(_ key: Key) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let value = _cache[key] { return value }
        if _cacheLoaded { return nil }
        if _isAccessDenied { return nil }

        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecUserCanceled || status == errSecAuthFailed {
            _isAccessDenied = true
            return nil
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        _cache[key] = value
        return value
    }

    static func delete(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        _cache.removeValue(forKey: key)
    }

    static func deleteAll() {
        for key in Key.allCases { delete(key) }
    }

    /// Pre-load all keys into memory. Call once at app startup.
    static func warmUpCache() {
        lock.lock()
        guard !_cacheLoaded else { lock.unlock(); return }
        lock.unlock()

        for key in Key.allCases { _ = load(key) }

        lock.lock()
        _cacheLoaded = true
        lock.unlock()
    }

    /// Clear denial state so the next `load` will try the keychain again.
    static func resetAccessDenied() {
        lock.lock()
        _isAccessDenied = false
        _cacheLoaded = false
        _cache.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecUseDataProtectionKeychain as String: true
        ]
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
