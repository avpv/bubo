import Foundation
import os

/// Imports tasks from Apple Reminders into the Bubo backlog.
///
/// Design mirrors `ReminderService` for calendar events:
///   - Always instantiated in `App.init`; never does work on init.
///   - `syncNow()` short-circuits when the feature is disabled or Reminders
///     access hasn't been granted — the popover can always open.
///   - Triggered explicitly from `MenuBarView.onAppear` via `startSync()`,
///     the same pattern as `reminderService.startSync()`.
///   - Import-only (no writeback to Apple Reminders) — matches the calendar
///     flow exactly and avoids the feedback-loop hazards that contributed
///     to the v1.10.30–v1.10.41 regressions.
private let logger = Logger(subsystem: "com.avpv.Bubo", category: "RemindersSyncService")

@MainActor
@Observable
final class RemindersSyncService {

    /// Posted after a sync imports new tasks. `object` is the count (Int).
    static let didImportTasks = Notification.Name("BuboRemindersDidImportTasks")

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    private(set) var importedCount: Int = 0

    private var settings: ReminderSettings
    private let backlogService: BacklogService

    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var remindersChangedObserver: Any?
    private var activeSyncTask: Task<Void, Never>?

    init(settings: ReminderSettings, backlogService: BacklogService) {
        self.settings = settings
        self.backlogService = backlogService

        // Listen for external changes (user edits Reminders.app, iCloud sync).
        // The callback short-circuits via `syncNow()` when the feature is off,
        // so this observer is cheap even for users who never enable the sync.
        remindersChangedObserver = NotificationCenter.default.addObserver(
            forName: AppleRemindersService.remindersDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
    }

    deinit {
        syncTimer?.invalidate()
        if let observer = remindersChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Update the settings reference. Call when `ReminderSettings` was reloaded
    /// (e.g. from iCloud). Safe to call at any time.
    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle (mirrors ReminderService)

    /// Mirrors `ReminderService.startSync()` — call once from
    /// `MenuBarView.onAppear` after the popover first opens.
    func startSync() {
        syncNow()
        startSyncTimer()
    }

    func startSyncTimer() {
        syncTimer?.invalidate()
        let interval = TimeInterval(settings.syncIntervalMinutes * 60)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
    }

    func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Sync

    func syncNow() {
        guard settings.isRemindersSyncEnabled else {
            syncError = nil
            return
        }

        guard AppleRemindersService.hasAccess else {
            syncError = "Reminders access not granted"
            return
        }

        // Prevent concurrent syncs — cancel any in-flight fetch.
        activeSyncTask?.cancel()

        isSyncing = true
        syncError = nil

        activeSyncTask = Task {
            let reminders = await AppleRemindersService.shared.fetchIncompleteReminders(
                fromListIds: settings.selectedRemindersListIds
            )
            guard !Task.isCancelled else { return }

            let existingIds = Set(backlogService.tasks.map(\.id))
            let defaultDuration = settings.remindersDefaultDurationMinutes
            var added = 0

            for reminder in reminders {
                let task = AppleRemindersService.shared.toBacklogTask(
                    reminder,
                    defaultDuration: defaultDuration
                )
                // Skip tasks that were already imported on a previous sync.
                // Tasks the user has deleted from the backlog will be
                // re-imported — we don't track dismissals yet.
                if !existingIds.contains(task.id) {
                    backlogService.addTask(task)
                    added += 1
                }
            }

            importedCount = added
            lastSyncDate = Date()
            isSyncing = false

            if added > 0 {
                NotificationCenter.default.post(name: Self.didImportTasks, object: added)
            }
        }
    }
}
