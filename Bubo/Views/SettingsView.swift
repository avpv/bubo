import SwiftUI

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(OptimizerService.self) var optimizerService
    @State private var viewModel = SettingsViewModel()
    @State private var selectedPane: SettingsPane = .general

    enum SettingsPane: String, CaseIterable, Identifiable {
        case general = "General"
        case calendars = "Calendars"
        case reminders = "Reminders"
        case optimizer = "Optimizer"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gear"
            case .calendars: "calendar"
            case .reminders: "bell"
            case .optimizer: "wand.and.stars"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch selectedPane {
                case .general:
                    GeneralTabView()
                case .calendars:
                    CalendarsTabView()
                case .reminders:
                    RemindersTabView()
                case .optimizer:
                    OptimizerTabView()
                }
            }
            .navigationTitle(selectedPane.rawValue)
        }
        .environment(viewModel)
        .environment(settings)
        .environment(reminderService)
        .environment(optimizerService)
        .frame(width: DS.Settings.width, height: DS.Settings.idealHeight)
    }
}
