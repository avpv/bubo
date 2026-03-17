import Foundation

@MainActor
@Observable
class SettingsViewModel {
    // MARK: - Reminders Tab
    var newIntervalMinutes = 10

    // MARK: - Apple Calendar
    var appleCalendarAccessGranted = AppleCalendarService.hasAccess
    var availableAppleCalendars: [AppleCalendarService.CalendarInfo] = []
    var appleCalendarsByAccount: [(account: String, calendars: [AppleCalendarService.CalendarInfo])] = []

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
