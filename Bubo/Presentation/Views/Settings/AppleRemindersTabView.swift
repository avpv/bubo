import SwiftUI
import BuboDomain
import BuboOptimizer

/// Native grouped Form — same Settings.app vocabulary as `GeneralTabView`.
/// Sections replace the previous full-width `SettingsPlatter` cards; the
/// per-account list picker renders as native sections like the Calendars
/// tab. Per-row explanations stay as footnote text under their row; the
/// section-level summary lives in the section footer.
struct AppleRemindersTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(SettingsViewModel.self) var viewModel
    @Environment(RemindersSyncService.self) var syncService
    @Environment(ReminderService.self) var reminderService
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var settings = settings

        Form {
            accessSection

            if settings.isRemindersSyncEnabled && viewModel.remindersAccessGranted {
                listSelectionSection
                importOptionsSection
                exportSection
                scheduleAlarmsSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Pull fresh status from the system — the ViewModel's cached value
            // can be stale if the user changed permission in System Settings
            // while the app was running.
            viewModel.refreshRemindersAuthStatus()
            if viewModel.remindersAccessGranted && viewModel.availableRemindersLists.isEmpty {
                viewModel.loadRemindersLists()
            }
        }
        // Auto-sync when access is granted for the first time — otherwise the
        // user taps Allow in the permission dialog and nothing visibly
        // happens until they manually click "Sync Now" or reopen the popover.
        .onChange(of: viewModel.remindersAuthStatus) { _, newStatus in
            guard newStatus == .fullAccess else { return }
            if viewModel.availableRemindersLists.isEmpty {
                viewModel.loadRemindersLists()
            }
            // Granting Reminders access changes TCC state for the shared
            // EKEventStore. Rebuild it so subsequent calendar + reminders
            // fetches see the new permission.  Without this, the existing
            // store keeps returning cached state and calendar events also
            // stop updating until the user relaunches the app.
            AppleCalendarService.shared.rebuildStore()
            reminderService.syncNow()
            if settings.isRemindersSyncEnabled {
                syncService.syncNow()
            }
        }
        // Auto-sync when the feature is toggled on while access is already
        // granted — matches how calendar sync reacts to its own enable toggle.
        .onChange(of: settings.isRemindersSyncEnabled) { _, enabled in
            guard enabled, viewModel.remindersAccessGranted else { return }
            syncService.syncNow()
        }
    }

    // MARK: - Access

    @ViewBuilder
    private var accessSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.isRemindersSyncEnabled) {
                Text("Import Reminders into Backlog")
                    .fontWeight(.regular)
            }
            .toggleStyle(.switch)

            if settings.isRemindersSyncEnabled {
                if viewModel.remindersAccessGranted {
                    HStack {
                        Label("Access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(skin.resolvedSuccessColor)
                        Spacer()
                        Text("\(viewModel.availableRemindersLists.count) lists")
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .font(.footnote)
                    }
                } else {
                    let status = viewModel.remindersAuthStatus
                    if status == .denied || status == .restricted {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Reminders access denied", systemImage: "xmark.circle.fill")
                                .foregroundStyle(skin.resolvedDestructiveColor)
                            Text("Grant access in System Settings\u{00A0}\u{2192}\u{00A0}Privacy & Security\u{00A0}\u{2192}\u{00A0}Reminders")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                            .help("Opens System Settings to configure Reminders privacy")
                        }
                    } else {
                        Button {
                            viewModel.requestRemindersAccess()
                        } label: {
                            if viewModel.isRequestingRemindersAccess {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Requesting Access…")
                            } else {
                                Label("Connect", systemImage: "checklist")
                            }
                        }
                        .buttonStyle(.action(role: .primary, size: .compact))
                        .disabled(viewModel.isRequestingRemindersAccess)
                    }
                }

                if viewModel.remindersAccessGranted {
                    HStack {
                        if syncService.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Syncing")
                            Text("Syncing…")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        } else if let date = syncService.lastSyncDate {
                            Text("Last sync: \(date, style: .relative) ago")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }

                        Spacer()

                        Button("Sync Now") {
                            syncService.syncNow()
                        }
                        .controlSize(.small)
                        .disabled(syncService.isSyncing)
                    }
                }
            }
        } header: {
            Text("Apple Reminders")
        } footer: {
            if settings.isRemindersSyncEnabled {
                Text("Incomplete reminders from selected lists are imported into the backlog for scheduling.")
            }
        }
    }

    // MARK: - List Selection

    @ViewBuilder
    private var listSelectionSection: some View {
        @Bindable var settings = settings
        let allLists = viewModel.availableRemindersLists

        Section {
            Toggle("All lists", isOn: Binding(
                get: { settings.selectedRemindersListIds.isEmpty },
                set: { isAll in
                    settings.selectedRemindersListIds = isAll ? [] : allLists.map { $0.id }
                }
            ))
            .fontWeight(.regular)
        } header: {
            Text("Lists")
        } footer: {
            Text(settings.selectedRemindersListIds.isEmpty
                ? "Importing from all \(allLists.count) lists"
                : "Selected: \(settings.selectedRemindersListIds.count) of \(allLists.count)")
        }

        if !settings.selectedRemindersListIds.isEmpty {
            ForEach(viewModel.remindersListsByAccount, id: \.account) { group in
                Section {
                    ForEach(group.lists) { list in
                        Toggle(isOn: Binding(
                            get: { settings.selectedRemindersListIds.contains(list.id) },
                            set: { isOn in
                                if isOn {
                                    if !settings.selectedRemindersListIds.contains(list.id) {
                                        settings.selectedRemindersListIds.append(list.id)
                                    }
                                } else {
                                    settings.selectedRemindersListIds.removeAll { $0 == list.id }
                                }
                                if settings.selectedRemindersListIds.count == allLists.count {
                                    settings.selectedRemindersListIds = []
                                }
                            }
                        )) {
                            HStack(spacing: DS.Spacing.sm) {
                                Circle()
                                    .fill(list.color.map { Color(cgColor: $0) } ?? skin.resolvedTextTertiary)
                                    .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                                Text(list.title)
                            }
                        }
                    }
                } header: {
                    Text(group.account)
                }
            }
        }
    }

    // MARK: - Import Options

    @ViewBuilder
    private var importOptionsSection: some View {
        @Bindable var settings = settings
        Section {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack {
                    Text("Default duration")
                        .fontWeight(.regular)
                    Spacer()
                    Stepper(
                        DS.formatMinutes(settings.remindersDefaultDurationMinutes),
                        value: $settings.remindersDefaultDurationMinutes,
                        in: 15...240,
                        step: 15
                    )
                    .monospacedDigit()
                }
                Text("Apple Reminders has no duration\u{00A0}\u{2014} this value is used for scheduling.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }

            // Checkbox, not switch — a single boolean inside a section
            // (HIG toggles: in general, don't replace a checkbox with a
            // switch; switches stay on the section masters above).
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Toggle(isOn: $settings.remindersCompletionSync) {
                    Text("Also mark done in Reminders")
                        .fontWeight(.regular)
                }
                Text("When you complete an imported task in Bubo, the original reminder is marked done too.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
        } header: {
            Text("Import Options")
        }

        if syncService.dismissedCount > 0 {
            dismissedRemindersSection
        }
    }

    // MARK: - Dismissed Reminders

    @ViewBuilder
    private var dismissedRemindersSection: some View {
        Section {
            HStack {
                Text("\(syncService.dismissedCount) reminder\(syncService.dismissedCount == 1 ? "" : "s") won\u{2019}t be re-imported")
                    .fontWeight(.regular)

                Spacer()

                Button("Clear") {
                    syncService.clearDismissedReminderIds()
                    syncService.syncNow()
                }
                .controlSize(.small)
            }
        } header: {
            Text("Dismissed Reminders")
        } footer: {
            Text("Reminders you deleted from the backlog are skipped on future syncs. Clear this list to import them again.")
        }
    }

    // MARK: - Export (Bubo → Apple Reminders)

    @ViewBuilder
    private var exportSection: some View {
        @Bindable var settings = settings
        let allLists = viewModel.availableRemindersLists

        Section {
            Toggle(isOn: $settings.remindersExportEnabled) {
                Text("Push Bubo tasks to Reminders")
                    .fontWeight(.regular)
            }
            .toggleStyle(.switch)

            if settings.remindersExportEnabled {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack {
                        Text("Target list")
                            .fontWeight(.regular)
                        Spacer()
                        Picker("Target list", selection: Binding(
                            get: { settings.remindersExportListId ?? "" },
                            set: { settings.remindersExportListId = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Default list").tag("")
                            ForEach(allLists) { list in
                                Text(list.title).tag(list.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text("New Bubo tasks are created in this Reminders list. Edits and schedule changes in Bubo also push back automatically.")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Toggle(isOn: $settings.remindersDeletionSync) {
                        Text("Delete reminder when task is removed")
                            .fontWeight(.regular)
                    }
                    Text("When you remove a linked task from the backlog, its reminder is deleted from Apple Reminders too.")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
            }
        } header: {
            Text("Sync to Apple Reminders")
        } footer: {
            Text("New tasks created in Bubo are added to Apple Reminders so they appear on iPhone, iPad, and other devices via iCloud.")
        }
    }

    // MARK: - Schedule Alarms (iPhone / iPad notifications)

    @ViewBuilder
    private var scheduleAlarmsSection: some View {
        @Bindable var settings = settings
        @Bindable var viewModel = viewModel

        Section {
            Toggle(isOn: $settings.remindersScheduleAlarms) {
                Text("Ring on iPhone at scheduled time")
                    .fontWeight(.regular)
            }

            if settings.remindersScheduleAlarms {
                Text("Also alert me ahead of time")
                    .fontWeight(.regular)

                ForEach($settings.remindersScheduleAlarmLeadMinutes) { $interval in
                    HStack {
                        Toggle(isOn: $interval.isEnabled) {
                            Text("\(interval.displayText) before")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            settings.remindersScheduleAlarmLeadMinutes
                                .removeAll { $0.id == interval.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(interval.displayText) lead-time alarm")
                        .help("Delete lead-time alarm")
                    }
                }

                HStack(spacing: DS.Spacing.sm) {
                    Text("Add: \(viewModel.newScheduleAlarmLeadMinutes)\u{00A0}min")
                        .frame(minWidth: 100, alignment: .leading)
                        .monospacedDigit()

                    Stepper(
                        "Lead-time minutes",
                        value: $viewModel.newScheduleAlarmLeadMinutes,
                        in: 1...120
                    )
                    .labelsHidden()

                    Spacer()

                    Button("Add Lead-Time Alarm") {
                        settings.remindersScheduleAlarmLeadMinutes.append(
                            ReminderInterval(minutes: viewModel.newScheduleAlarmLeadMinutes)
                        )
                    }
                }
            }
        } header: {
            Text("iPhone & iPad Notifications")
        } footer: {
            if settings.remindersScheduleAlarms {
                Text("An alarm always fires at the scheduled time. Lead-time alarms stack on top so you get a heads-up before the task starts. Requires iCloud Reminders enabled on the device and notifications allowed for Reminders.app.")
            } else {
                Text("When a backlog task is scheduled in Bubo, an alarm is added to the linked Reminder so iPhone and iPad ring at that moment via iCloud.")
            }
        }
    }
}
