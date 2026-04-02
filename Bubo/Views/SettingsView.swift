import Combine
import SwiftUI

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(OptimizerService.self) var optimizerService
    @State private var viewModel = SettingsViewModel()
    @State private var selectedPane: SettingsPane = .general

    enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
        case general = "General"
        case calendars = "Calendars"
        case reminders = "Reminders"
        case worldClock = "World Clock"
        case optimizer = "Schedule Assistant"

        var id: String { rawValue }

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

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            switch selectedPane {
            case .general:
                GeneralTabView()
            case .calendars:
                CalendarsTabView()
            case .reminders:
                RemindersTabView()
            case .worldClock:
                WorldClockTabView()
            case .optimizer:
                OptimizerTabView()
            }
        }
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
