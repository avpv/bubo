import SwiftUI
import BuboDomain
import BuboOptimizer

/// Native grouped Form — same Settings.app vocabulary as `GeneralTabView`.
/// The per-account calendar list renders as native sections (one per
/// account) instead of a hand-built Grid with separator rows.
struct CalendarsTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(SettingsViewModel.self) var viewModel
    @Environment(ReminderService.self) var reminderService
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var settings = settings

        Form {
            accessSection

            if settings.isCalendarSyncEnabled && viewModel.appleCalendarAccessGranted {
                calendarSelectionSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Pull fresh status from the system — the ViewModel's cached value
            // can be stale if the user changed permission in System Settings
            // while the app was running.
            viewModel.refreshCalendarAuthStatus()
            if viewModel.appleCalendarAccessGranted && viewModel.availableAppleCalendars.isEmpty {
                viewModel.loadAppleCalendars()
            }
        }
        // Auto-sync calendar events once access is granted — without this, the
        // popover stays empty until the next 5-minute sync-timer tick even
        // though the user just clicked Connect. Mirrors the Reminders tab.
        .onChange(of: viewModel.calendarAuthStatus) { _, newStatus in
            guard newStatus == .fullAccess else { return }
            if viewModel.availableAppleCalendars.isEmpty {
                viewModel.loadAppleCalendars()
            }
            // Rebuild the shared EKEventStore so the fresh TCC grant is
            // picked up before we read events. `requestAccess` already does
            // this once, but onChange can fire for System-Settings grants
            // that never routed through the in-app Connect button.
            AppleCalendarService.shared.rebuildStore()
            reminderService.syncNow()
        }
    }

    // MARK: - Access

    @ViewBuilder
    private var accessSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.isCalendarSyncEnabled) {
                Text("Sync Apple Calendar Events")
                    .fontWeight(.regular)
            }
            .toggleStyle(.switch)

            if settings.isCalendarSyncEnabled {
                if viewModel.appleCalendarAccessGranted {
                    HStack {
                        Label("Access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(skin.resolvedSuccessColor)
                        Spacer()
                        Text("\(viewModel.availableAppleCalendars.count) calendars")
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .font(.footnote)
                    }
                } else {
                    let status = viewModel.calendarAuthStatus
                    if status == .denied || status == .restricted {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Calendar access denied", systemImage: "xmark.circle.fill")
                                .foregroundStyle(skin.resolvedDestructiveColor)
                            Text("Grant access in System Settings\u{00A0}\u{2192}\u{00A0}Privacy & Security\u{00A0}\u{2192}\u{00A0}Calendars")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                            .help("Opens System Settings to configure Calendar privacy")
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
                        .buttonStyle(.action(role: .primary, size: .compact))
                        .disabled(viewModel.isRequestingCalendarAccess)
                    }
                }
            }
        } header: {
            Text("Calendar Access")
        } footer: {
            if settings.isCalendarSyncEnabled {
                Text("Bubo reads events from all accounts configured in the Calendar app \u{2014} iCloud, Google, Exchange, CalDAV, and others.")
            }
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
            .fontWeight(.regular)
        } header: {
            Text("Calendars")
        } footer: {
            Text(settings.selectedCalendarIds.isEmpty
                ? "Showing all \(allCalendars.count) calendars"
                : "Selected: \(settings.selectedCalendarIds.count) of \(allCalendars.count)")
        }

        if !settings.selectedCalendarIds.isEmpty {
            ForEach(viewModel.appleCalendarsByAccount, id: \.account) { group in
                Section {
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
                                    .fill(cal.color.map { Color(cgColor: $0) } ?? skin.resolvedTextTertiary)
                                    .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                                Text(cal.title)
                            }
                        }
                    }
                } header: {
                    Text(group.account)
                }
            }
        }
    }
}
