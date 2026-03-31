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
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                ForEach(SettingsPane.allCases, id: \.self) { pane in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedPane = pane
                        }
                    } label: {
                        Label(pane.rawValue, systemImage: pane.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedPane == pane ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedPane == pane ? .primary : .secondary)
                }
            }
            .padding(12)
            .frame(width: 170)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.ultraThinMaterial)

            Divider()

            // Detail
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(viewModel)
        .environment(settings)
        .environment(reminderService)
        .environment(optimizerService)
        .frame(width: DS.Settings.width, height: DS.Settings.idealHeight)
        .toolbar(removing: .sidebarToggle)
    }
}
