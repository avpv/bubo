import AppKit
import EventKit
import Foundation

@MainActor
@Observable
class SettingsViewModel {
    /// Set before opening Settings to navigate to a specific pane.
    static var pendingPane: SettingsView.SettingsPane?

    /// Posted when a deep-link navigation to a specific pane is requested.
    static let navigateToPaneNotification = Notification.Name("SettingsViewModel.navigateToPane")

    // MARK: - Reminders Tab
    var newIntervalMinutes = 10

    // MARK: - Apple Calendar
    var calendarAuthStatus = AppleCalendarService.authorizationStatus
    var isRequestingCalendarAccess = false
    var availableAppleCalendars: [AppleCalendarService.CalendarInfo] = []
    var appleCalendarsByAccount: [(account: String, calendars: [AppleCalendarService.CalendarInfo])] = []

    var appleCalendarAccessGranted: Bool {
        calendarAuthStatus == .fullAccess
    }

    // MARK: - Apple Reminders
    var remindersAuthStatus = AppleRemindersService.authorizationStatus
    var isRequestingRemindersAccess = false
    var availableRemindersLists: [AppleRemindersService.RemindersList] = []
    var remindersListsByAccount: [(account: String, lists: [AppleRemindersService.RemindersList])] = []

    var remindersAccessGranted: Bool {
        remindersAuthStatus == .fullAccess
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
                // The shared EKEventStore caches the pre-grant TCC state; rebuild
                // so `listCalendars()` below (and later fetches) see the new
                // permission instead of returning empty results.
                AppleCalendarService.shared.rebuildStore()
                loadAppleCalendars()
            }
        }
    }

    /// Refreshes the cached calendar authorization status from the system.
    /// Call this when Settings appears so grants/denials made outside the
    /// Connect button (e.g. via System Settings) are reflected in the UI.
    func refreshCalendarAuthStatus() {
        let current = AppleCalendarService.authorizationStatus
        if calendarAuthStatus != current {
            calendarAuthStatus = current
        }
    }

    func loadAppleCalendars() {
        availableAppleCalendars = AppleCalendarService.shared.listCalendars()
        appleCalendarsByAccount = AppleCalendarService.shared.listCalendarsByAccount()
    }

    func requestRemindersAccess() {
        guard !isRequestingRemindersAccess else { return }
        isRequestingRemindersAccess = true

        Task {
            let granted = await AppleRemindersService.shared.requestAccess()

            remindersAuthStatus = AppleRemindersService.authorizationStatus
            isRequestingRemindersAccess = false
            if granted {
                // Same cache issue as the calendar flow — the pre-grant store
                // keeps returning stale TCC state until it's rebuilt.
                AppleCalendarService.shared.rebuildStore()
                loadRemindersLists()
            }
        }
    }

    /// Refreshes the cached Reminders authorization status from the system.
    func refreshRemindersAuthStatus() {
        let current = AppleRemindersService.authorizationStatus
        if remindersAuthStatus != current {
            remindersAuthStatus = current
        }
    }

    func loadRemindersLists() {
        availableRemindersLists = AppleRemindersService.shared.listRemindersLists()
        remindersListsByAccount = AppleRemindersService.shared.listsByAccount()
    }
}
