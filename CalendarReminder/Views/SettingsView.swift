import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        TabView {
            AccountTabView(settings: settings, reminderService: reminderService, viewModel: viewModel)
                .tabItem { Label("Account", systemImage: "person.circle") }

            CalendarsTabView(settings: settings, reminderService: reminderService, viewModel: viewModel)
                .tabItem { Label("Calendars", systemImage: "calendar") }

            RemindersTabView(settings: settings, reminderService: reminderService, viewModel: viewModel)
                .tabItem { Label("Reminders", systemImage: "bell") }

            GeneralTabView(settings: settings, reminderService: reminderService, viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 480, height: 460)
    }
}
