import SwiftUI
import BuboDomain
import BuboOptimizer

struct AppleRemindersTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(SettingsViewModel.self) var viewModel
    @Environment(RemindersSyncService.self) var syncService
    @Environment(ReminderService.self) var reminderService
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                accessSection

                if settings.isRemindersSyncEnabled && viewModel.remindersAccessGranted {
                    listSelectionSection
                    importOptionsSection
                    exportSection
                    scheduleAlarmsSection
                }
            }
            .padding(DS.Spacing.xl)
        }
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
        SettingsPlatter("Apple Reminders") {
            Toggle(isOn: $settings.isRemindersSyncEnabled) {
                Text("Import Reminders into Backlog")
                    .fontWeight(.regular)
            }
            .toggleStyle(.switch)

            if settings.isRemindersSyncEnabled {
                SkinSeparator().padding(.vertical, DS.Spacing.xs)

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

                Text("Incomplete reminders from selected lists are imported into the backlog for scheduling.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .padding(.top, DS.Spacing.xs)

                if viewModel.remindersAccessGranted {
                    SkinSeparator().padding(.vertical, DS.Spacing.xs)

                    HStack {
                        if syncService.isSyncing {
                            ProgressView()
                                .controlSize(.small)
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
        }
    }

    // MARK: - List Selection

    @ViewBuilder
    private var listSelectionSection: some View {
        @Bindable var settings = settings
        let allLists = viewModel.availableRemindersLists

        SettingsPlatter("Lists") {
            Toggle("All lists", isOn: Binding(
                get: { settings.selectedRemindersListIds.isEmpty },
                set: { isAll in
                    settings.selectedRemindersListIds = isAll ? [] : allLists.map { $0.id }
                }
            ))
            .fontWeight(.regular)

            Text(settings.selectedRemindersListIds.isEmpty
                ? "Importing from all \(allLists.count) lists"
                : "Selected: \(settings.selectedRemindersListIds.count) of \(allLists.count)")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
        }

        if !settings.selectedRemindersListIds.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.sm) {
                ForEach(viewModel.remindersListsByAccount, id: \.account) { group in
                    GridRow {
                        SkinSeparator().padding(.vertical, DS.Spacing.xs)
                    }
                    GridRow {
                        Text(group.account).font(.subheadline).foregroundStyle(skin.resolvedTextSecondary)
                    }

                    ForEach(group.lists) { list in
                        GridRow {
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
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.lg)
        }
    }

    // MARK: - Import Options

    @ViewBuilder
    private var importOptionsSection: some View {
        @Bindable var settings = settings
        SettingsPlatter("Import Options") {
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm) {
                GridRow {
                    Text("Default duration")
                        .fontWeight(.regular)

                    Stepper(
                        DS.formatMinutes(settings.remindersDefaultDurationMinutes),
                        value: $settings.remindersDefaultDurationMinutes,
                        in: 15...240,
                        step: 15
                    )
                    .monospacedDigit()
                }
            }

            Text("Apple Reminders has no duration\u{00A0}\u{2014} this value is used for scheduling.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.top, DS.Spacing.xs)

            SkinSeparator().padding(.vertical, DS.Spacing.xs)

            // Checkbox, not switch — a single boolean inside a section
            // (HIG toggles: in general, don't replace a checkbox with a
            // switch; switches stay on the section masters above).
            Toggle(isOn: $settings.remindersCompletionSync) {
                Text("Also mark done in Reminders")
                    .fontWeight(.regular)
            }

            Text("When you complete an imported task in Bubo, the original reminder is marked done too.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.top, DS.Spacing.xs)
        }

        if syncService.dismissedCount > 0 {
            dismissedRemindersSection
        }
    }

    // MARK: - Dismissed Reminders

    @ViewBuilder
    private var dismissedRemindersSection: some View {
        SettingsPlatter("Dismissed Reminders") {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("\(syncService.dismissedCount) reminder\(syncService.dismissedCount == 1 ? "" : "s") won\u{2019}t be re-imported")
                        .fontWeight(.regular)
                    Text("Reminders you deleted from the backlog are skipped on future syncs. Clear this list to import them again.")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("Clear") {
                    syncService.clearDismissedReminderIds()
                    syncService.syncNow()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Export (Bubo → Apple Reminders)

    @ViewBuilder
    private var exportSection: some View {
        @Bindable var settings = settings
        let allLists = viewModel.availableRemindersLists

        SettingsPlatter("Sync to Apple Reminders") {
            Toggle(isOn: $settings.remindersExportEnabled) {
                Text("Push Bubo tasks to Reminders")
                    .fontWeight(.regular)
            }
            .toggleStyle(.switch)

            Text("New tasks created in Bubo are added to Apple Reminders so they appear on iPhone, iPad, and other devices via iCloud.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.top, DS.Spacing.xs)

            if settings.remindersExportEnabled {
                SkinSeparator().padding(.vertical, DS.Spacing.xs)

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("Target list")
                        .fontWeight(.regular)

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

                    Text("New Bubo tasks are created in this Reminders list. Edits and schedule changes in Bubo also push back automatically.")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }

                SkinSeparator().padding(.vertical, DS.Spacing.xs)

                Toggle(isOn: $settings.remindersDeletionSync) {
                    Text("Delete reminder when task is removed")
                        .fontWeight(.regular)
                }

                Text("When you remove a linked task from the backlog, its reminder is deleted from Apple Reminders too.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .padding(.top, DS.Spacing.xs)
            }
        }
    }

    // MARK: - Schedule Alarms (iPhone / iPad notifications)

    @ViewBuilder
    private var scheduleAlarmsSection: some View {
        @Bindable var settings = settings
        @Bindable var viewModel = viewModel

        SettingsPlatter("iPhone & iPad notifications") {
            Toggle(isOn: $settings.remindersScheduleAlarms) {
                Text("Ring on iPhone at scheduled time")
                    .fontWeight(.regular)
            }

            Text("When a backlog task is scheduled in Bubo, an alarm is added to the linked Reminder so iPhone and iPad ring at that moment via iCloud. Requires iCloud Reminders enabled on the device and notifications allowed for Reminders.app.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.top, DS.Spacing.xs)

            if settings.remindersScheduleAlarms {
                SkinSeparator().padding(.vertical, DS.Spacing.xs)

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

                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm) {
                    GridRow {
                        Text("Add: \(viewModel.newScheduleAlarmLeadMinutes)\u{00A0}min")
                            .frame(minWidth: 100, alignment: .leading)
                            .monospacedDigit()

                        Stepper(
                            "Lead-time minutes",
                            value: $viewModel.newScheduleAlarmLeadMinutes,
                            in: 1...120
                        )
                        .labelsHidden()

                        Button("Add Lead-Time Alarm") {
                            settings.remindersScheduleAlarmLeadMinutes.append(
                                ReminderInterval(minutes: viewModel.newScheduleAlarmLeadMinutes)
                            )
                        }
                    }
                }

                Text("An alarm always fires at the scheduled time. Lead-time alarms stack on top so you get a heads-up before the task starts.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .padding(.top, DS.Spacing.xs)
            }
        }
    }
}
