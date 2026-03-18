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
            // LSUIElement apps need to temporarily become regular apps
            // so macOS shows the calendar permission dialog on top.
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            
            // Wait for the policy change to propagate so the dialog isn't suppressed
            try? await Task.sleep(nanoseconds: 500_000_000)

            let granted = await AppleCalendarService.shared.requestAccess()

            // Restore menu-bar-only activation policy or keep previous if settings window is still open.
            let isSettingsOpen = NSApp.windows.contains { $0.isVisible && ($0.title.contains("Settings") || $0.identifier?.rawValue.contains("Settings") == true) }
            if isSettingsOpen {
                NSApp.setActivationPolicy(previousPolicy)
            } else {
                NSApp.setActivationPolicy(.accessory)
                if NSApp.isActive {
                    NSApp.hide(nil)
                }
            }

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
