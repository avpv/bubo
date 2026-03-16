import Foundation

@MainActor
class SettingsViewModel: ObservableObject {
    // MARK: - Reminders Tab
    @Published var newIntervalMinutes = 10

    // MARK: - Account Tab (Yandex)
    @Published var connectionStatus: ConnectionStatus = .unknown
    @Published var oauthCode = ""
    @Published var oauthStatus: OAuthStatus = .idle

    // MARK: - Account Tab (Google)
    @Published var googleOAuthCode = ""
    @Published var googleOAuthStatus: OAuthStatus = .idle

    // MARK: - Calendars Tab (Yandex)
    @Published var availableCalendars: [CalDAVXMLParser.CalendarInfo] = []
    @Published var isLoadingCalendars = false
    @Published var calendarLoadError: String?

    // MARK: - Calendars Tab (Google)
    @Published var availableGoogleCalendars: [GoogleCalendarService.CalendarListEntry] = []
    @Published var isLoadingGoogleCalendars = false
    @Published var googleCalendarLoadError: String?

    enum ConnectionStatus {
        case unknown, checking, success, failed(String)
    }

    enum OAuthStatus {
        case idle, exchanging, success, failed(String)
    }

    // MARK: - Actions

    func saveSettings(_ settings: ReminderSettings, _ reminderService: ReminderService) {
        settings.save()
        reminderService.updateSettings(settings)
    }

    func checkConnection(settings: ReminderSettings, reminderService: ReminderService) {
        connectionStatus = .checking
        saveSettings(settings, reminderService)
        reminderService.setupCalDAVService()

        let authMode: YandexCalDAVService.AuthMode
        switch settings.authMethod {
        case .appPassword:
            authMode = .appPassword(login: settings.yandexLogin, password: settings.yandexAppPassword)
        case .oauth:
            authMode = .oauth
        }

        let service = YandexCalDAVService(authMode: authMode)

        Task {
            do {
                let now = Date()
                let end = Calendar.current.date(byAdding: .day, value: 1, to: now)!
                _ = try await service.fetchEvents(from: now, to: end)
                connectionStatus = .success
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }

    func exchangeOAuthCode() {
        oauthStatus = .exchanging
        Task {
            do {
                _ = try await YandexOAuthService.exchangeCode(oauthCode)
                oauthStatus = .success
                oauthCode = ""
            } catch {
                oauthStatus = .failed(error.localizedDescription)
            }
        }
    }

    func exchangeGoogleOAuthCode(settings: ReminderSettings, reminderService: ReminderService) {
        googleOAuthStatus = .exchanging
        Task {
            do {
                _ = try await GoogleOAuthService.exchangeCode(googleOAuthCode)
                googleOAuthStatus = .success
                googleOAuthCode = ""
                saveSettings(settings, reminderService)
            } catch {
                googleOAuthStatus = .failed(error.localizedDescription)
            }
        }
    }

    func loadYandexCalendars(settings: ReminderSettings) {
        isLoadingCalendars = true
        calendarLoadError = nil

        let authMode: YandexCalDAVService.AuthMode
        switch settings.authMethod {
        case .appPassword:
            authMode = .appPassword(login: settings.yandexLogin, password: settings.yandexAppPassword)
        case .oauth:
            authMode = .oauth
        }

        let service = YandexCalDAVService(authMode: authMode)

        Task {
            do {
                let calendars = try await service.listCalendars()
                availableCalendars = calendars.filter { $0.isCalendar }
                isLoadingCalendars = false
            } catch {
                calendarLoadError = error.localizedDescription
                isLoadingCalendars = false
            }
        }
    }

    func loadGoogleCalendars() {
        isLoadingGoogleCalendars = true
        googleCalendarLoadError = nil

        let service = GoogleCalendarService()
        Task {
            do {
                availableGoogleCalendars = try await service.listCalendars()
                isLoadingGoogleCalendars = false
            } catch {
                googleCalendarLoadError = error.localizedDescription
                isLoadingGoogleCalendars = false
            }
        }
    }
}
