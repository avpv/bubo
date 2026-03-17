import SwiftUI

struct CalendarsTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(SettingsViewModel.self) var viewModel

    var body: some View {
        @Bindable var settings = settings

        Form {
            accessSection

            if viewModel.appleCalendarAccessGranted {
                calendarSelectionSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if viewModel.appleCalendarAccessGranted && viewModel.availableAppleCalendars.isEmpty {
                viewModel.loadAppleCalendars()
            }
        }
    }

    // MARK: - Access

    @ViewBuilder
    private var accessSection: some View {
        Section("Calendar Access") {
            if viewModel.appleCalendarAccessGranted {
                HStack {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Spacer()
                    Text("\(viewModel.availableAppleCalendars.count) calendars")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            } else {
                let status = viewModel.calendarAuthStatus
                if status == .denied || status == .restricted {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Label("Calendar access denied", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("Grant access in System Settings \u{2192} Privacy & Security \u{2192} Calendars")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        viewModel.requestAppleCalendarAccess()
                    } label: {
                        if viewModel.isRequestingCalendarAccess {
                            ProgressView()
                                .controlSize(.small)
                            Text("Requesting Access…")
                        } else {
                            Label("Connect", systemImage: "calendar")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRequestingCalendarAccess)
                }
            }

            Text("Owlenda reads events from all accounts configured in the Calendar app \u{2014} iCloud, Google, Exchange, CalDAV, and others.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Calendar Selection

    @ViewBuilder
    private var calendarSelectionSection: some View {
        @Bindable var settings = settings
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
                ? "Showing all \(allCalendars.count) calendars"
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
                                if settings.selectedCalendarIds.count == allCalendars.count {
                                    settings.selectedCalendarIds = []
                                }
                            }
                        )) {
                            HStack(spacing: DS.Spacing.sm) {
                                Circle()
                                    .fill(Color(cgColor: cal.color ?? CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)))
                                    .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                                Text(cal.title)
                            }
                        }
                    }
                }
            }
        }
    }
}
