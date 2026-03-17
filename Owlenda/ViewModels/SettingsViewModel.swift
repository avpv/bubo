import Foundation

@MainActor
class SettingsViewModel: ObservableObject {
    // MARK: - Reminders Tab
    @Published var newIntervalMinutes = 10

    // MARK: - Apple Calendar
    @Published var appleCalendarAccessGranted = AppleCalendarService.hasAccess
    @Published var availableAppleCalendars: [AppleCalendarService.CalendarInfo] = []
    @Published var appleCalendarsByAccount: [(account: String, calendars: [AppleCalendarService.CalendarInfo])] = []

    // MARK: - Actions

    func requestAppleCalendarAccess() {
        Task {
            let granted = await AppleCalendarService.shared.requestAccess()
            appleCalendarAccessGranted = granted
            if granted {
                loadAppleCalendars()
            }
        }
    }

    func loadAppleCalendars() {
        availableAppleCalendars = AppleCalendarService.shared.listCalendars()
        appleCalendarsByAccount = AppleCalendarService.shared.listCalendarsByAccount()
    }
}
