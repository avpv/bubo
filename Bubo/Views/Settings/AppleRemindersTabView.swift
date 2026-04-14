import SwiftUI

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
                }
            }
            .padding(DS.Spacing.xl)
        }
        .onAppear {
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
                    .fontWeight(.medium)
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
                            .font(.caption)
                    }
                } else {
                    let status = viewModel.remindersAuthStatus
                    if status == .denied || status == .restricted {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Reminders access denied", systemImage: "xmark.circle.fill")
                                .foregroundStyle(skin.resolvedDestructiveColor)
                            Text("Grant access in System Settings\u{00A0}\u{2192}\u{00A0}Privacy & Security\u{00A0}\u{2192}\u{00A0}Reminders")
                                .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .padding(.top, DS.Spacing.xs)

                if viewModel.remindersAccessGranted {
                    SkinSeparator().padding(.vertical, DS.Spacing.xs)

                    HStack {
                        if syncService.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing…")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        } else if let date = syncService.lastSyncDate {
                            Text("Last sync: \(date, style: .relative) ago")
                                .font(.caption)
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
            .fontWeight(.medium)

            Text(settings.selectedRemindersListIds.isEmpty
                ? "Importing from all \(allLists.count) lists"
                : "Selected: \(settings.selectedRemindersListIds.count) of \(allLists.count)")
                .font(.caption)
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
                        .fontWeight(.medium)

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
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.top, DS.Spacing.xs)

            SkinSeparator().padding(.vertical, DS.Spacing.xs)

            Toggle(isOn: $settings.remindersCompletionSync) {
                Text("Also mark done in Reminders")
                    .fontWeight(.medium)
            }
            .toggleStyle(.switch)

            Text("When you complete an imported task in Bubo, the original reminder is marked done too.")
                .font(.caption)
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
                        .fontWeight(.medium)
                    Text("Reminders you deleted from the backlog are skipped on future syncs. Clear this list to import them again.")
                        .font(.caption)
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
}
