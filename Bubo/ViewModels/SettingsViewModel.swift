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

            // Trust the grant result. `EKEventStore.authorizationStatus` can
            // briefly still return `.notDetermined` right after the completion
            // handler fires — TCC propagation to EventKit's class-level cache
            // lags behind the continuation. If we read the static query here
            // we occasionally flip the UI back to the Connect button even
            // though the user just tapped Allow.
            calendarAuthStatus = granted
                ? .fullAccess
                : AppleCalendarService.authorizationStatus
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
        // Never downgrade a known grant to `.notDetermined` — the static
        // query is occasionally stale (especially right after we grant
        // Reminders access on the same shared store), and `.notDetermined`
        // isn't reachable from `.fullAccess` without the user revoking
        // via System Settings, which the OS reports as `.denied`.
        if calendarAuthStatus == .fullAccess, current == .notDetermined {
            return
        }
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

            // Same race as the calendar flow — trust `granted` over the
            // static query to avoid the UI bouncing back to Connect.
            remindersAuthStatus = granted
                ? .fullAccess
                : AppleRemindersService.authorizationStatus
            isRequestingRemindersAccess = false
            if granted {
                // Same cache issue as the calendar flow — the pre-grant store
                // keeps returning stale TCC state until it's rebuilt.
                AppleCalendarService.shared.rebuildStore()
                loadRemindersLists()
                // Granting Reminders reshapes the shared store's TCC view;
                // re-check Calendar so we don't accidentally keep a stale
                // `.fullAccess` if it was actually revoked meanwhile, but
                // also don't drop a real grant on a stale `.notDetermined`.
                refreshCalendarAuthStatus()
            }
        }
    }

    /// Refreshes the cached Reminders authorization status from the system.
    func refreshRemindersAuthStatus() {
        let current = AppleRemindersService.authorizationStatus
        // Mirror `refreshCalendarAuthStatus` — protect a known grant from
        // being downgraded by a stale `.notDetermined` read.
        if remindersAuthStatus == .fullAccess, current == .notDetermined {
            return
        }
        if remindersAuthStatus != current {
            remindersAuthStatus = current
        }
    }

    func loadRemindersLists() {
        availableRemindersLists = AppleRemindersService.shared.listRemindersLists()
        remindersListsByAccount = AppleRemindersService.shared.listsByAccount()
    }
}
