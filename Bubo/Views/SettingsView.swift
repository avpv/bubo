import SwiftUI

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(OptimizerService.self) var optimizerService
    @State private var viewModel = SettingsViewModel()
    @State private var selectedPane: SettingsPane = .general

    enum SettingsPane: String, CaseIterable, Hashable {
        case general = "General"
        case calendars = "Calendars"
        case reminders = "Reminders"
        case worldClock = "World Clock"
        case optimizer = "Schedule Assistant"

        var icon: String {
            switch self {
            case .general: "gear"
            case .calendars: "calendar"
            case .reminders: "bell"
            case .worldClock: "globe"
            case .optimizer: "wand.and.stars.inverse"
            }
        }
    }

    /// HIG: macOS Settings windows use standard toolbar tab navigation.
    var body: some View {
        TabView(selection: $selectedPane) {
            GeneralTabView()
                .tabItem { Label(SettingsPane.general.rawValue, systemImage: SettingsPane.general.icon) }
                .tag(SettingsPane.general)

            CalendarsTabView()
                .tabItem { Label(SettingsPane.calendars.rawValue, systemImage: SettingsPane.calendars.icon) }
                .tag(SettingsPane.calendars)

            RemindersTabView()
                .tabItem { Label(SettingsPane.reminders.rawValue, systemImage: SettingsPane.reminders.icon) }
                .tag(SettingsPane.reminders)

            WorldClockTabView()
                .tabItem { Label(SettingsPane.worldClock.rawValue, systemImage: SettingsPane.worldClock.icon) }
                .tag(SettingsPane.worldClock)

            OptimizerTabView()
                .tabItem { Label(SettingsPane.optimizer.rawValue, systemImage: SettingsPane.optimizer.icon) }
                .tag(SettingsPane.optimizer)
        }
        .environment(viewModel)
        .environment(settings)
        .environment(reminderService)
        .environment(optimizerService)
        .frame(minWidth: DS.Settings.width, maxWidth: DS.Settings.width, minHeight: DS.Settings.minHeight)
        .onAppear {
            if let pending = SettingsViewModel.pendingPane {
                selectedPane = pending
                SettingsViewModel.pendingPane = nil
            }
        }
    }
}
