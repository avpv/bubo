import SwiftUI

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(OptimizerService.self) var optimizerService
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralTabView()
                .tabItem { Label("General", systemImage: "gear") }

            CalendarsTabView()
                .tabItem { Label("Calendars", systemImage: "calendar") }

            RemindersTabView()
                .tabItem { Label("Reminders", systemImage: "bell") }

            OptimizerTabView()
                .tabItem { Label("Optimizer", systemImage: "wand.and.stars") }
        }
        .environment(viewModel)
        .environment(settings)
        .environment(reminderService)
        .environment(optimizerService)
        .navigationTitle("Bubo Settings")
        .frame(minHeight: DS.Settings.minHeight, idealHeight: DS.Settings.idealHeight)
        .frame(width: DS.Settings.width)
    }
}
