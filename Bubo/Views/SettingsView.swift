import SwiftUI

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralTabView()
                .tabItem { Label("General", systemImage: "gear") }

            CalendarsTabView()
                .tabItem { Label("Calendars", systemImage: "calendar") }

            RemindersTabView()
                .tabItem { Label("Reminders", systemImage: "bell") }
        }
        .environment(viewModel)
        .environment(settings)
        .environment(reminderService)
        .navigationTitle("Bubo Settings")
        .frame(minHeight: DS.Settings.minHeight, idealHeight: DS.Settings.idealHeight)
        .frame(width: DS.Settings.width)
    }
}
