import Combine
import SwiftUI

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(OptimizerService.self) var optimizerService
    @Environment(AgentService.self) var agentService
    @State private var viewModel = SettingsViewModel()
    @State private var selectedPane: SettingsPane = .general

    enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case calendars = "Calendars"
        case reminders = "Reminders"
        case worldClock = "World Clock"
        case assistant = "Assistant"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gear"
            case .appearance: "paintbrush"
            case .calendars: "calendar"
            case .reminders: "bell"
            case .worldClock: "globe"
            case .assistant: "wand.and.sparkles"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: DS.Settings.sidebarWidth)
            .scrollContentBackground(.visible)

            Divider()

            Group {
                switch selectedPane {
                case .general:
                    GeneralTabView()
                case .appearance:
                    AppearanceTabView()
                case .calendars:
                    CalendarsTabView()
                case .reminders:
                    RemindersTabView()
                case .worldClock:
                    WorldClockTabView()
                case .assistant:
                    AssistantTabView(agentService: agentService)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("\(selectedPane.rawValue) | Bubo")
        .toolbar(.hidden)
        .environment(viewModel)
        .environment(settings)
        .environment(reminderService)
        .environment(optimizerService)
        .frame(minWidth: DS.Settings.sidebarWidth + DS.Settings.detailWidth, minHeight: DS.Settings.minHeight)
        .onAppear {
            if let pending = SettingsViewModel.pendingPane {
                selectedPane = pending
                SettingsViewModel.pendingPane = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsViewModel.navigateToPaneNotification)) { notification in
            if let pane = notification.object as? SettingsPane {
                selectedPane = pane
                SettingsViewModel.pendingPane = nil
            }
        }
    }
}
