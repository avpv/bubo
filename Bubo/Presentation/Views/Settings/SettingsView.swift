import Combine
import SwiftUI
import BuboDomain

struct SettingsView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(OptimizerService.self) var optimizerService
    @Environment(AgentService.self) var agentService
    @State private var viewModel = SettingsViewModel()
    @State private var selectedPane: SettingsPane = SettingsViewModel.lastViewedPane

    enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case calendars = "Calendars"
        case appleReminders = "Reminders"
        case notifications = "Notifications"
        case worldClock = "World Clock"
        case optimizer = "Optimizer"
        case assistant = "Assistant"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gear"
            case .appearance: "paintbrush"
            case .calendars: "calendar"
            case .appleReminders: "checklist"
            case .notifications: "bell"
            case .worldClock: "globe"
            case .optimizer: "slider.horizontal.3"
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
                case .appleReminders:
                    AppleRemindersTabView()
                case .notifications:
                    RemindersTabView()
                case .worldClock:
                    WorldClockTabView()
                case .optimizer:
                    OptimizerTabView()
                case .assistant:
                    AssistantTabView(agentService: agentService)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Just the pane name — System Settings titles a window «General»,
        // not «General | App» (HIG windows: write a brief title; the app
        // name is already on the Settings scene).
        .navigationTitle(selectedPane.rawValue)
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
        .onChange(of: selectedPane) { _, newPane in
            // Persist the user's choice so next `⌘,` opens here directly.
            // Skipped while a deep-link is being applied — `pendingPane`
            // overrides the saved value but shouldn't pollute it.
            SettingsViewModel.lastViewedPane = newPane
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsViewModel.navigateToPaneNotification)) { notification in
            if let pane = notification.object as? SettingsPane {
                selectedPane = pane
                SettingsViewModel.pendingPane = nil
            }
        }
    }
}
