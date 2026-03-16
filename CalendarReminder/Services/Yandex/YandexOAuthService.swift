import Foundation
import AppKit

actor YandexOAuthService {
    private static var clientId: String { AppConfig.yandexClientId }
    private static var clientSecret: String { AppConfig.yandexClientSecret }
    private static var redirectURI: String { AppConfig.yandexRedirectURI }
    private static var authURL: String { AppConfig.yandexAuthURL }
    private static var tokenURL: String { AppConfig.yandexTokenURL }

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
        guard var components = URLComponents(string: authURL) else { return }
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
        guard let url = URL(string: tokenURL) else {
            throw OAuthError.tokenExchangeFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

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

        guard let url = URL(string: tokenURL) else {
            throw OAuthError.refreshFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

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
        KeychainService.delete(.yandexLogin)
        KeychainService.delete(.yandexAppPassword)
    }
}

enum OAuthError: LocalizedError {
    case tokenExchangeFailed
    case refreshFailed
    case noRefreshToken
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .tokenExchangeFailed: return "Failed to obtain token"
        case .refreshFailed: return "Failed to refresh token"
        case .noRefreshToken: return "Missing refresh token"
        case .notAuthenticated: return "Authorization required"
        }
    }
}
