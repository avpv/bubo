import Foundation
import AppKit

actor YandexOAuthService {
    // Register your app at https://oauth.yandex.ru/ to get these values
    // Required scopes: calendar:read
    static let clientId = "YOUR_CLIENT_ID"
    static let clientSecret = "YOUR_CLIENT_SECRET"
    private static let redirectURI = "https://oauth.yandex.ru/verification_code"
    private static let authURL = "https://oauth.yandex.ru/authorize"
    private static let tokenURL = "https://oauth.yandex.ru/token"

    struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    /// Opens browser for OAuth authorization
    static func startAuthFlow() {
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "calendar:read"),
            URLQueryItem(name: "force_confirm", value: "yes")
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Exchange authorization code for tokens
    static func exchangeCode(_ code: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OAuthError.tokenExchangeFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        // Save tokens to Keychain
        try KeychainService.save(tokenResponse.accessToken, for: .oauthAccessToken)
        if let refreshToken = tokenResponse.refreshToken {
            try KeychainService.save(refreshToken, for: .oauthRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try KeychainService.save(expiry.ISO8601Format(), for: .oauthTokenExpiry)

        return tokenResponse
    }

    /// Refresh expired access token
    static func refreshAccessToken() async throws -> TokenResponse {
        guard let refreshToken = KeychainService.load(.oauthRefreshToken) else {
            throw OAuthError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OAuthError.refreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        try KeychainService.save(tokenResponse.accessToken, for: .oauthAccessToken)
        if let refreshToken = tokenResponse.refreshToken {
            try KeychainService.save(refreshToken, for: .oauthRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try KeychainService.save(expiry.ISO8601Format(), for: .oauthTokenExpiry)

        return tokenResponse
    }

    /// Get a valid access token, refreshing if needed
    static func getValidAccessToken() async throws -> String {
        guard let token = KeychainService.load(.oauthAccessToken) else {
            throw OAuthError.notAuthenticated
        }

        // Check if token is expired
        if let expiryStr = KeychainService.load(.oauthTokenExpiry),
           let expiry = ISO8601DateFormatter().date(from: expiryStr),
           expiry < Date().addingTimeInterval(60) { // refresh 60s before expiry
            let newToken = try await refreshAccessToken()
            return newToken.accessToken
        }

        return token
    }

    static var isAuthenticated: Bool {
        KeychainService.load(.oauthAccessToken) != nil
    }

    static func logout() {
        KeychainService.delete(.oauthAccessToken)
        KeychainService.delete(.oauthRefreshToken)
        KeychainService.delete(.oauthTokenExpiry)
    }
}

enum OAuthError: LocalizedError {
    case tokenExchangeFailed
    case refreshFailed
    case noRefreshToken
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .tokenExchangeFailed: return "Не удалось получить токен"
        case .refreshFailed: return "Не удалось обновить токен"
        case .noRefreshToken: return "Отсутствует refresh token"
        case .notAuthenticated: return "Необходима авторизация"
        }
    }
}
