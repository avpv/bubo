import SwiftUI

@main
struct YandexCalendarReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings: ReminderSettings
    @StateObject private var reminderService: ReminderService

    init() {
        let s = ReminderSettings.load()
        _settings = StateObject(wrappedValue: s)
        _reminderService = StateObject(wrappedValue: ReminderService(settings: s))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: settings, reminderService: reminderService)
        } label: {
            Label("Календарь", systemImage: "calendar.badge.clock")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, reminderService: reminderService)
        }
    }
}
