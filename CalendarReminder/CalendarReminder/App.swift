import SwiftUI

@main
struct CalendarReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings: ReminderSettings
    @StateObject private var reminderService: ReminderService
    @StateObject private var networkMonitor = NetworkMonitor()

    init() {
        let s = ReminderSettings.load()
        _settings = StateObject(wrappedValue: s)
        _reminderService = StateObject(wrappedValue: ReminderService(settings: s))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                settings: settings,
                reminderService: reminderService,
                networkMonitor: networkMonitor
            )
        } label: {
            Label("Reminder", systemImage: "calendar.badge.clock")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, reminderService: reminderService)
        }
    }
}
