import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: ReminderSettings
    @EnvironmentObject var reminderService: ReminderService
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        TabView {
            AccountTabView()
                .tabItem { Label("Account", systemImage: "person.circle") }

            CalendarsTabView()
                .tabItem { Label("Calendars", systemImage: "calendar") }

            RemindersTabView()
                .tabItem { Label("Reminders", systemImage: "bell") }

            GeneralTabView()
                .tabItem { Label("General", systemImage: "gear") }
        }
        .environmentObject(viewModel)
        .frame(minHeight: DS.Settings.minHeight, idealHeight: DS.Settings.idealHeight)
        .frame(width: DS.Settings.width)
    }
}
