import AppKit
import EventKit
import Foundation

@MainActor
@Observable
class SettingsViewModel {
    // MARK: - Reminders Tab
    var newIntervalMinutes = 10

    // MARK: - Apple Calendar
    var calendarAuthStatus = AppleCalendarService.authorizationStatus
    var isRequestingCalendarAccess = false
    var availableAppleCalendars: [AppleCalendarService.CalendarInfo] = []
    var appleCalendarsByAccount: [(account: String, calendars: [AppleCalendarService.CalendarInfo])] = []

    var appleCalendarAccessGranted: Bool {
        if #available(macOS 14.0, *) {
            calendarAuthStatus == .fullAccess
        } else {
            calendarAuthStatus == .authorized
        }
    }

    // MARK: - Actions

    func requestAppleCalendarAccess() {
        guard !isRequestingCalendarAccess else { return }
        isRequestingCalendarAccess = true

        Task {
            let granted = await AppleCalendarService.shared.requestAccess()

            calendarAuthStatus = AppleCalendarService.authorizationStatus
            isRequestingCalendarAccess = false
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
