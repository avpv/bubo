import Foundation
import AppKit

actor GoogleOAuthService {
    private static var clientId: String { AppConfig.googleClientId }
    private static var clientSecret: String { AppConfig.googleClientSecret }
    private static var redirectURI: String { AppConfig.googleRedirectURI }
    private static var authURL: String { AppConfig.googleAuthURL }
    private static var tokenURL: String { AppConfig.googleTokenURL }
    private static var scope: String { AppConfig.googleCalendarScope }

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

    static func startAuthFlow() {
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    static func exchangeCode(_ code: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code=\(code)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "redirect_uri=\(redirectURI)",
            "grant_type=authorization_code"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GoogleAuthError.tokenExchangeFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        try KeychainService.save(tokenResponse.accessToken, for: .googleAccessToken)
        if let refreshToken = tokenResponse.refreshToken {
            try KeychainService.save(refreshToken, for: .googleRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try KeychainService.save(expiry.ISO8601Format(), for: .googleTokenExpiry)

        return tokenResponse
    }

    static func refreshAccessToken() async throws -> TokenResponse {
        guard let refreshToken = KeychainService.load(.googleRefreshToken) else {
            throw GoogleAuthError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "refresh_token=\(refreshToken)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GoogleAuthError.refreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        try KeychainService.save(tokenResponse.accessToken, for: .googleAccessToken)
        if let refreshToken = tokenResponse.refreshToken {
            try KeychainService.save(refreshToken, for: .googleRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try KeychainService.save(expiry.ISO8601Format(), for: .googleTokenExpiry)

        return tokenResponse
    }

    static func getValidAccessToken() async throws -> String {
        guard let token = KeychainService.load(.googleAccessToken) else {
            throw GoogleAuthError.notAuthenticated
        }

        if let expiryStr = KeychainService.load(.googleTokenExpiry),
           let expiry = ISO8601DateFormatter().date(from: expiryStr),
           expiry < Date().addingTimeInterval(60) {
            let newToken = try await refreshAccessToken()
            return newToken.accessToken
        }

        return token
    }

    static var isAuthenticated: Bool {
        KeychainService.load(.googleAccessToken) != nil
    }

    static func logout() {
        KeychainService.delete(.googleAccessToken)
        KeychainService.delete(.googleRefreshToken)
        KeychainService.delete(.googleTokenExpiry)
    }
}

enum GoogleAuthError: LocalizedError {
    case tokenExchangeFailed
    case refreshFailed
    case noRefreshToken
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .tokenExchangeFailed: return "Failed to obtain Google token"
        case .refreshFailed: return "Failed to refresh Google token"
        case .noRefreshToken: return "Missing Google refresh token"
        case .notAuthenticated: return "Google authorization required"
        }
    }
}
