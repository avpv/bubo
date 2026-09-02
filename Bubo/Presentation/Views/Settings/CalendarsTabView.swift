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
    @Environment(CalDAVVerificationService.self) var calDAVVerifier
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var settings = settings

        Form {
            accessSection

            if settings.isCalendarSyncEnabled && viewModel.appleCalendarAccessGranted {
                calendarSelectionSection
                serverVerificationSection
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

                    // Universal recovery for stale calendar data: tear
                    // down and re-open the connection to macOS calendar
                    // data, prod the remote pull, re-sync. Equivalent to
                    // relaunching the app, one click. Safe here because
                    // it is user-initiated — the periodic sync path must
                    // never rebuild the shared store (PR #588).
                    Button {
                        AppleCalendarService.shared.rebuildStore()
                        AppleCalendarService.shared.triggerRemoteRefresh()
                        reminderService.syncNow()
                        viewModel.loadAppleCalendars()
                    } label: {
                        Label("Force Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Rebuilds the calendar connection and re-syncs \u{2014} use if deleted events linger or new ones don't appear")
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

        calendarAccountSections
    }

    // MARK: - Server Verification (ghost-event detection)

    /// Opt-in CalDAV cross-check for accounts whose macOS sync drops
    /// deletions (Yandex Calendar is the known case): events the server
    /// no longer has are hidden automatically, even though EventKit
    /// still serves them. Read-only against the server; nothing in
    /// Apple Calendar is modified.
    @ViewBuilder
    private var serverVerificationSection: some View {
        @Bindable var calDAVVerifier = calDAVVerifier
        Section {
            Toggle(isOn: $calDAVVerifier.isEnabled) {
                Text("Verify events with CalDAV server")
                    .fontWeight(.regular)
            }
            .toggleStyle(.switch)

            if calDAVVerifier.isEnabled {
                TextField(
                    "Server URL",
                    text: $calDAVVerifier.serverURLString,
                    prompt: Text(CalDAVVerificationService.defaultServerURL)
                )
                .autocorrectionDisabled()

                TextField(
                    "Username",
                    text: $calDAVVerifier.username,
                    prompt: Text("user@yandex.ru")
                )
                .autocorrectionDisabled()

                SecureField("App password", text: $calDAVVerifier.appPassword)

                // Scope to one Calendar account so same-named calendars
                // in other accounts are never touched.
                Picker("Calendar account", selection: $calDAVVerifier.accountName) {
                    Text("Select account\u{2026}").tag("")
                    ForEach(viewModel.appleCalendarsByAccount, id: \.account) { group in
                        Text(group.account).tag(group.account)
                    }
                }

                HStack {
                    Button {
                        Task { await calDAVVerifier.verifyNow() }
                    } label: {
                        if calDAVVerifier.isVerifying {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking\u{2026}")
                        } else {
                            Label("Check Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .controlSize(.small)
                    .disabled(calDAVVerifier.isVerifying)

                    Spacer()

                    if let error = calDAVVerifier.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedDestructiveColor)
                    } else if calDAVVerifier.lastVerification != nil {
                        Text(calDAVVerifier.ghostKeys.isEmpty
                            ? "All events confirmed on server"
                            : "\(calDAVVerifier.ghostKeys.count) deleted on server \u{2014} hidden")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }
            }
        } header: {
            Text("Server Verification")
        } footer: {
            Text("For accounts whose macOS sync misses deletions (e.g. Yandex Calendar): Bubo asks the CalDAV server which events still exist and hides the ones deleted there. Read-only \u{2014} use an app password; nothing is changed on the server or in Apple Calendar.")
        }
    }

    /// Per-account calendar toggles — the tail of the selection UI,
    /// split into its own property purely for size; rendered by
    /// `calendarSelectionSection` right after the summary section.
    @ViewBuilder
    private var calendarAccountSections: some View {
        let allCalendars = viewModel.availableAppleCalendars
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
