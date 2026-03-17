import SwiftUI

struct CalendarsTabView: View {
    @EnvironmentObject var settings: ReminderSettings
    @EnvironmentObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            if !viewModel.appleCalendarAccessGranted {
                Section {
                    Label("Grant calendar access in the Account tab first", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
            } else if viewModel.appleCalendarsByAccount.isEmpty {
                Section {
                    Text("No calendars found")
                        .foregroundColor(.secondary)
                }
            } else {
                let allCalendars = viewModel.availableAppleCalendars

                Section {
                    Toggle("All calendars", isOn: Binding(
                        get: { settings.selectedCalendarIds.isEmpty },
                        set: { isAll in
                            settings.selectedCalendarIds = isAll ? [] : allCalendars.map { $0.id }
                        }
                    ))
                    .fontWeight(.medium)

                    Text(settings.selectedCalendarIds.isEmpty
                        ? "Syncing all \(allCalendars.count) calendars"
                        : "Selected: \(settings.selectedCalendarIds.count) of \(allCalendars.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !settings.selectedCalendarIds.isEmpty {
                    ForEach(viewModel.appleCalendarsByAccount, id: \.account) { group in
                        Section(group.account) {
                            ForEach(group.calendars) { cal in
                                Toggle(isOn: Binding(
                                    get: { settings.selectedCalendarIds.contains(cal.id) },
                                    set: { isOn in
                                        if isOn {
                                            if !settings.selectedCalendarIds.contains(cal.id) {
                                                settings.selectedCalendarIds.append(cal.id)
                                            }
                                        } else {
                                            settings.selectedCalendarIds.removeAll { $0 == cal.id }
                                        }
                                        // If all selected, reset to "all"
                                        if settings.selectedCalendarIds.count == allCalendars.count {
                                            settings.selectedCalendarIds = []
                                        }
                                    }
                                )) {
                                    HStack(spacing: DS.Spacing.sm) {
                                        Circle()
                                            .fill(Color(cgColor: cal.color ?? CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)))
                                            .frame(width: 10, height: 10)
                                        Text(cal.title)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if viewModel.appleCalendarAccessGranted && viewModel.availableAppleCalendars.isEmpty {
                viewModel.loadAppleCalendars()
            }
        }
    }
}
