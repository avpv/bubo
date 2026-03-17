import EventKit
import SwiftUI

struct CalendarsTabView: View {
    @EnvironmentObject var settings: ReminderSettings
    @EnvironmentObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            if settings.appleCalendarEnabled && AppleCalendarService.hasAccess {
                Section("Apple Calendar") {
                    if viewModel.appleCalendarsByAccount.isEmpty {
                        Text("No calendars found")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        appleCalendarToggles
                    }
                }
                .onAppear {
                    if viewModel.availableAppleCalendars.isEmpty {
                        viewModel.loadAppleCalendars()
                    }
                }
            }

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

    // MARK: - Apple Calendar Toggles (grouped by account, with color dots)

    @ViewBuilder
    private var appleCalendarToggles: some View {
        let allCalendars = viewModel.availableAppleCalendars

        Toggle("All calendars", isOn: Binding(
            get: { settings.selectedAppleCalendarIds.isEmpty },
            set: { isAll in
                settings.selectedAppleCalendarIds = isAll ? [] : allCalendars.map { $0.id }
            }
        ))
        .fontWeight(.medium)

        if !settings.selectedAppleCalendarIds.isEmpty {
            ForEach(viewModel.appleCalendarsByAccount, id: \.account) { group in
                Text(group.account)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, DS.Spacing.xs)

                ForEach(group.calendars) { cal in
                    Toggle(isOn: Binding(
                        get: { settings.selectedAppleCalendarIds.contains(cal.id) },
                        set: { isOn in
                            if isOn {
                                if !settings.selectedAppleCalendarIds.contains(cal.id) {
                                    settings.selectedAppleCalendarIds.append(cal.id)
                                }
                            } else {
                                settings.selectedAppleCalendarIds.removeAll { $0 == cal.id }
                            }
                            if settings.selectedAppleCalendarIds.count == allCalendars.count {
                                settings.selectedAppleCalendarIds = []
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

        Text(settings.selectedAppleCalendarIds.isEmpty
            ? "Syncing all"
            : "Selected: \(settings.selectedAppleCalendarIds.count) of \(allCalendars.count)")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: - Generic Calendar Toggles

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
