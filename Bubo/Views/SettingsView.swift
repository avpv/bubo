import SwiftUI

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(OptimizerService.self) var optimizerService
    @State private var viewModel = SettingsViewModel()
    @State private var selectedPane: SettingsPane? = .general

    enum SettingsPane: String, CaseIterable, Hashable {
        case general = "General"
        case calendars = "Calendars"
        case reminders = "Reminders"
        case optimizer = "Optimizer"

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
            List(selection: $selectedPane) {
                ForEach(SettingsPane.allCases, id: \.self) { pane in
                    Label(pane.rawValue, systemImage: pane.icon)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selectedPane ?? .general {
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
            .navigationTitle(selectedPane?.rawValue ?? "General")
        }
        .environment(viewModel)
        .environment(settings)
        .environment(reminderService)
        .environment(optimizerService)
        .frame(width: DS.Settings.width, height: DS.Settings.idealHeight)
    }
}
