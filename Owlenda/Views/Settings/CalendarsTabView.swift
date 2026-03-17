import SwiftUI

struct CalendarsTabView: View {
    @EnvironmentObject var settings: ReminderSettings
    @EnvironmentObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Yandex Calendar") {
                HStack {
                    Button {
                        viewModel.loadYandexCalendars(settings: settings)
                    } label: {
                        Label("Load Calendars", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoadingCalendars)

                    if viewModel.isLoadingCalendars {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if let error = viewModel.calendarLoadError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundColor(.red).font(.caption)
                }

                if !viewModel.availableCalendars.isEmpty {
                    calendarToggles(
                        calendars: viewModel.availableCalendars.map { ($0.href, $0.displayName) },
                        selected: $settings.selectedCalendarHrefs
                    )
                }
            }

            if settings.googleEnabled && GoogleOAuthService.isAuthenticated {
                Section("Google Calendar") {
                    HStack {
                        Button {
                            viewModel.loadGoogleCalendars()
                        } label: {
                            Label("Load Calendars", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoadingGoogleCalendars)

                        if viewModel.isLoadingGoogleCalendars {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    if let error = viewModel.googleCalendarLoadError {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red).font(.caption)
                    }

                    if !viewModel.availableGoogleCalendars.isEmpty {
                        calendarToggles(
                            calendars: viewModel.availableGoogleCalendars.map { ($0.id, $0.summary) },
                            selected: $settings.selectedGoogleCalendarIds
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func calendarToggles(
        calendars: [(id: String, name: String)],
        selected: Binding<[String]>
    ) -> some View {
        Toggle("All calendars", isOn: Binding(
            get: { selected.wrappedValue.isEmpty },
            set: { isAll in
                selected.wrappedValue = isAll ? [] : calendars.map { $0.id }
            }
        ))
        .fontWeight(.medium)

        if !selected.wrappedValue.isEmpty {
            ForEach(calendars, id: \.id) { cal in
                Toggle(cal.name, isOn: Binding(
                    get: { selected.wrappedValue.contains(cal.id) },
                    set: { isOn in
                        if isOn {
                            if !selected.wrappedValue.contains(cal.id) {
                                selected.wrappedValue.append(cal.id)
                            }
                        } else {
                            selected.wrappedValue.removeAll { $0 == cal.id }
                        }
                        if selected.wrappedValue.count == calendars.count {
                            selected.wrappedValue = []
                        }
                    }
                ))
            }
        }

        Text(selected.wrappedValue.isEmpty
            ? "Syncing all"
            : "Selected: \(selected.wrappedValue.count) of \(calendars.count)")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
