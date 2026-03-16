import Foundation

enum AppConfig {
    // MARK: - Yandex OAuth
    // Register your app at https://oauth.yandex.ru/
    // Required scopes: calendar:read
    static let yandexClientId = "YOUR_CLIENT_ID"
    static let yandexClientSecret = "YOUR_CLIENT_SECRET"
    static let yandexRedirectURI = "https://oauth.yandex.ru/verification_code"
    static let yandexAuthURL = "https://oauth.yandex.ru/authorize"
    static let yandexTokenURL = "https://oauth.yandex.ru/token"

    // MARK: - Google OAuth
    // Register at https://console.cloud.google.com/
    // Enable Google Calendar API, create OAuth 2.0 credentials (Desktop app)
    static let googleClientId = "YOUR_GOOGLE_CLIENT_ID"
    static let googleClientSecret = "YOUR_GOOGLE_CLIENT_SECRET"
    static let googleRedirectURI = "urn:ietf:wg:oauth:2.0:oob"
    static let googleAuthURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let googleTokenURL = "https://oauth2.googleapis.com/token"
    static let googleCalendarScope = "https://www.googleapis.com/auth/calendar.readonly"

    // MARK: - CalDAV
    static let yandexCalDAVBaseURL = "https://caldav.yandex.ru"

    // MARK: - Google Calendar API
    static let googleCalendarBaseURL = "https://www.googleapis.com/calendar/v3"
}
