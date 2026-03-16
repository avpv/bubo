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

    private var menuBarIcon: NSImage {
        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = false
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        return NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Reminder")!
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                settings: settings,
                reminderService: reminderService,
                networkMonitor: networkMonitor
            )
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, reminderService: reminderService)
        }
    }
}
