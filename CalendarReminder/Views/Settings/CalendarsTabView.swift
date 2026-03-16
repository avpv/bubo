import SwiftUI

struct CalendarsTabView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Yandex Calendars
                SettingsCard(icon: "calendar", title: "Yandex Calendars", description: "Choose which calendars to sync") {
                    VStack(spacing: 8) {
                        HStack {
                            Button {
                                viewModel.loadYandexCalendars(settings: settings)
                            } label: {
                                Label("Load Calendars", systemImage: "arrow.clockwise")
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(viewModel.isLoadingCalendars)

                            if viewModel.isLoadingCalendars {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }

                            Spacer()
                        }

                        if let error = viewModel.calendarLoadError {
                            Label(error, systemImage: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }

                        if !viewModel.availableCalendars.isEmpty {
                            calendarToggles(
                                calendars: viewModel.availableCalendars.map { ($0.href, $0.displayName) },
                                selected: $settings.selectedCalendarHrefs
                            )
                        }
                    }
                }

                // Google Calendars
                if settings.googleEnabled && GoogleOAuthService.isAuthenticated {
                    SettingsCard(icon: "calendar.badge.plus", title: "Google Calendars", description: "Choose which Google calendars to sync") {
                        VStack(spacing: 8) {
                            HStack {
                                Button {
                                    viewModel.loadGoogleCalendars()
                                } label: {
                                    Label("Load Calendars", systemImage: "arrow.clockwise")
                                        .font(.system(.caption, design: .rounded).weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(viewModel.isLoadingGoogleCalendars)

                                if viewModel.isLoadingGoogleCalendars {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                }

                                Spacer()
                            }

                            if let error = viewModel.googleCalendarLoadError {
                                Label(error, systemImage: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.red)
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
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func calendarToggles(
        calendars: [(id: String, name: String)],
        selected: Binding<[String]>
    ) -> some View {
        VStack(spacing: 4) {
            Toggle(isOn: Binding(
                get: { selected.wrappedValue.isEmpty },
                set: { isAll in
                    selected.wrappedValue = isAll ? [] : calendars.map { $0.id }
                    save()
                }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text("All calendars")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if !selected.wrappedValue.isEmpty {
                ForEach(calendars, id: \.id) { cal in
                    Toggle(isOn: Binding(
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
                            save()
                        }
                    )) {
                        Text(cal.name)
                            .font(.system(.subheadline, design: .rounded))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.leading, 22)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text(selected.wrappedValue.isEmpty
                    ? "Syncing all calendars"
                    : "Selected: \(selected.wrappedValue.count) of \(calendars.count)")
                    .font(.system(.caption2, design: .rounded))
            }
            .foregroundColor(.secondary)
            .padding(.top, 2)
        }
    }

    private func save() {
        viewModel.saveSettings(settings, reminderService)
    }
}
