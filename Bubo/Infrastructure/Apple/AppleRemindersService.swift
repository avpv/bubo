import EventKit
import Foundation
import os
import BuboDomain

private let appleRemindersLogger = Logger(subsystem: "com.avpv.Bubo", category: "AppleReminders")

/// Provides read/write access to the user's Apple Reminders via EventKit.
///
/// Reuses AppleCalendarService's shared EKEventStore — Apple discourages
/// creating multiple instances ("creating multiple instances is expensive").
/// Manages its own authorization flow for the `.reminder` entity type.
@MainActor
@Observable
final class AppleRemindersService {

    static let shared = AppleRemindersService()

    /// Shared store owned by AppleCalendarService — single EKEventStore
    /// for the entire app, as Apple recommends.
    private var store: EKEventStore { AppleCalendarService.sharedStore }

    /// Posted when the EKEventStore detects external changes to reminders
    /// (e.g. user edits in Reminders.app or iCloud sync).
    nonisolated static let remindersDataChanged = Notification.Name("AppleRemindersDataChanged")

    /// Posted when the user resolves the Reminders permission prompt (grant
    /// or deny) via the in-app Connect button. Listeners — notably the menu
    /// bar's "Reminders access not granted" banner — refresh their cached
    /// `hasAccess` snapshot in response so the UI stops showing the banner
    /// the moment access is granted.
    nonisolated static let authorizationDidChange = Notification.Name("AppleRemindersAuthorizationDidChange")

    private var storeChangedObserver: Any?

    private init() {
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: Self.remindersDataChanged, object: nil)
        }
    }

    deinit {
        if let observer = MainActor.assumeIsolated({ storeChangedObserver }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Authorization

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    static var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToReminders()
            // Fire-and-forget signal so views that snapshot `hasAccess`
            // (e.g. the menu bar permission banner) can refresh without
            // having to poll a static EventKit property. Carry the
            // definitive `granted` result — `EKEventStore.authorizationStatus`
            // can still return `.notDetermined` for a beat after the
            // continuation resolves, and listeners that trust only the
            // static query end up stuck on the stale pre-grant state.
            NotificationCenter.default.post(
                name: Self.authorizationDidChange,
                object: nil,
                userInfo: ["granted": granted]
            )
            return granted
        } catch {
            appleRemindersLogger.error("Failed to request full Reminders access: \(error)")
            NotificationCenter.default.post(name: Self.authorizationDidChange, object: nil)
            return false
        }
    }

    // MARK: - List Reminders Lists

    struct RemindersList: Identifiable {
        let id: String
        let title: String
        let accountName: String
        let color: CGColor?

        var displayName: String { title }
    }

    func listRemindersLists() -> [RemindersList] {
        store.calendars(for: .reminder).map { cal in
            RemindersList(
                id: cal.calendarIdentifier,
                title: cal.title,
                accountName: cal.source.title,
                color: cal.cgColor
            )
        }
        .sorted { a, b in
            if a.accountName != b.accountName { return a.accountName < b.accountName }
            return a.title < b.title
        }
    }

    func listsByAccount() -> [(account: String, lists: [RemindersList])] {
        let all = listRemindersLists()
        let grouped = Dictionary(grouping: all) { $0.accountName }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (account: $0.key, lists: $0.value) }
    }

    // MARK: - Create List

    /// Creates a new Reminders list (EKCalendar with `.reminder` entityType)
    /// in the user's default Reminders source — usually iCloud, falling back
    /// to Local. Used by the backlog header's project picker «+ New
    /// Project…» to give Bubo a Reminders.app-style way to spin up an
    /// empty project without leaving the app. Returns the created list's
    /// `calendarIdentifier` so callers can immediately set it as the
    /// active project.
    ///
    /// Errors propagate: EventKit can refuse if the source is read-only
    /// (rare for the user's iCloud / Local sources but possible for
    /// shared accounts) or if the title collides on the same source.
    func createList(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "List name can't be empty."]
            )
        }
        // Pick a writable source. `defaultCalendarForNewReminders` may be
        // nil if no list exists yet, so we fall back to the first source
        // that EventKit reports as a reminders host.
        let source: EKSource? = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { src in
                src.sourceType == .calDAV || src.sourceType == .local || src.sourceType == .exchange
            })
        guard let source else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "No writable Reminders source available."]
            )
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = trimmed
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
    }

    // MARK: - Fetch Incomplete Reminders

    /// Fetches all incomplete reminders from the specified lists (or all lists if empty).
    func fetchIncompleteReminders(fromListIds listIds: [String] = []) async -> [EKReminder] {
        let calendars: [EKCalendar]?
        if listIds.isEmpty {
            calendars = nil
        } else {
            calendars = store.calendars(for: .reminder).filter {
                listIds.contains($0.calendarIdentifier)
            }
            // If no matching calendars found, return empty
            if calendars?.isEmpty == true { return [] }
        }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }


    // MARK: - Complete Reminder

    /// Marks a reminder as completed in Apple Reminders.
    /// Call this when the user completes the corresponding BacklogTask in Bubo.
    func completeReminder(calendarItemId: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Reminder not found."]
            )
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)
    }

    /// Extracts the Apple Reminders calendarItemIdentifier from a Bubo task ID.
    /// Returns nil if the task didn't originate from Reminders.
    static func remindersId(from backlogTaskId: String) -> String? {
        guard backlogTaskId.hasPrefix("reminder_") else { return nil }
        return String(backlogTaskId.dropFirst("reminder_".count))
    }

    // MARK: - Create Reminder (Export Bubo → Apple Reminders)

    /// Creates a new Apple Reminder from a BacklogTask.
    /// Returns the `calendarItemIdentifier` of the created reminder.
    func createReminder(from task: BacklogTask, inListId listId: String?) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = task.title
        reminder.priority = Self.appleRemindersPriority(from: task.priority)
        reminder.notes = Self.composeNotes(
            notes: task.notes,
            url: task.url,
            subtasks: task.subtasks,
            tags: task.tags
        )
        if let loc = task.location, !loc.isEmpty {
            reminder.location = loc
        }

        if let deadline = task.deadline {
            reminder.dueDateComponents = Self.dueDateComponents(from: deadline)
        }

        // Assign to the specified list, or default list
        if let listId,
           let calendar = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listId }) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        if task.status == .done {
            reminder.isCompleted = true
            reminder.completionDate = task.completedAt ?? Date()
        }

        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Updates an existing Apple Reminder with current BacklogTask values.
    /// Returns `true` if any fields were changed, `false` if the reminder
    /// already matched the task (no write was performed — saves an EventKit
    /// round-trip and avoids a superfluous store-changed notification).
    @discardableResult
    func updateReminder(calendarItemId: String, from task: BacklogTask) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Reminder not found for update."]
            )
        }

        let newPriority = Self.appleRemindersPriority(from: task.priority)
        let newDueComponents: DateComponents? = task.deadline.map(Self.dueDateComponents(from:))
        let shouldBeDone = task.status == .done
        let newNotes = Self.composeNotes(
            notes: task.notes,
            url: task.url,
            subtasks: task.subtasks,
            tags: task.tags
        )
        let newLocation = task.location.flatMap { $0.isEmpty ? nil : $0 }

        // Field-by-field diff — skip the save if nothing actually changed.
        var didChange = false
        if reminder.title != task.title { reminder.title = task.title; didChange = true }
        if reminder.priority != newPriority { reminder.priority = newPriority; didChange = true }
        if reminder.dueDateComponents != newDueComponents {
            reminder.dueDateComponents = newDueComponents
            didChange = true
        }
        if reminder.notes != newNotes {
            reminder.notes = newNotes
            didChange = true
        }
        if reminder.location != newLocation {
            reminder.location = newLocation
            didChange = true
        }
        if reminder.isCompleted != shouldBeDone {
            reminder.isCompleted = shouldBeDone
            reminder.completionDate = shouldBeDone ? (task.completedAt ?? Date()) : nil
            didChange = true
        }

        guard didChange else { return false }
        try store.save(reminder, commit: true)
        return true
    }

    /// Deletes a reminder from Apple Reminders. Silently succeeds if the
    /// reminder no longer exists (e.g. already deleted on another device).
    func deleteReminder(calendarItemId: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            return
        }
        try store.remove(reminder, commit: true)
    }

    /// Sets the reminder's due-date and alarms in a single write. Used by
    /// the Bubo scheduling writeback — `scheduledDate` replaces the
    /// reminder's due date so iPhone users see the time slot Bubo assigned
    /// the task, and `alarmDates` installs `EKAlarm`s so iPhone / iPad
    /// actually ring at the scheduled moment (and any user-configured
    /// lead times). Pass `nil` for `dueDate` to clear the due slot, and
    /// an empty `alarmDates` to clear all alarms. Returns `true` if
    /// anything actually changed; callers can skip logging when nothing
    /// needed writing.
    @discardableResult
    func updateReminderSchedule(
        calendarItemId: String,
        dueDate: Date?,
        alarmDates: [Date]
    ) throws -> Bool {
        try mutateSchedule(
            calendarItemId: calendarItemId,
            dueDate: dueDate,
            alarmDates: alarmDates,
            commit: true
        )
    }

    /// Apply many schedule updates as a single EventKit transaction.
    /// Each save runs with `commit: false` and a single `commit()` flushes
    /// the lot — turns a sweep over 50 scheduled tasks into one
    /// `EKEventStoreChanged` echo instead of 50.
    @discardableResult
    func applyScheduleUpdates(_ updates: [ScheduleUpdate]) throws -> Int {
        var changed = 0
        for update in updates {
            // Per-reminder errors fail the whole batch — same contract as
            // single updates. Callers already log + recover at a higher
            // level, so we don't try to keep partial progress here.
            let didMutate = try mutateSchedule(
                calendarItemId: update.calendarItemId,
                dueDate: update.dueDate,
                alarmDates: update.alarmDates,
                commit: false
            )
            if didMutate { changed += 1 }
        }
        if changed > 0 {
            try store.commit()
        }
        return changed
    }

    /// Shared diff-then-write helper. `commit: false` queues the change
    /// for a later `store.commit()` — used by `applyScheduleUpdates` to
    /// batch many writes into one EventKit transaction.
    private func mutateSchedule(
        calendarItemId: String,
        dueDate: Date?,
        alarmDates: [Date],
        commit: Bool
    ) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Reminder not found for schedule update."]
            )
        }

        let newComponents: DateComponents? = dueDate.map(Self.dueDateComponents(from:))
        let dueChanged = reminder.dueDateComponents != newComponents

        // Compare alarms by their absolute fire-date set, ignoring order.
        // EKAlarm equality isn't suitable here — two alarms with identical
        // `absoluteDate` aren't `==` because the class doesn't override it.
        let existingDates = (reminder.alarms ?? [])
            .compactMap { $0.absoluteDate }
            .sorted()
        let desiredDates = alarmDates.sorted()
        let alarmsChanged = existingDates != desiredDates

        guard dueChanged || alarmsChanged else { return false }

        if dueChanged {
            reminder.dueDateComponents = newComponents
        }
        if alarmsChanged {
            // Drop every existing alarm and install fresh ones. Reminders
            // doesn't support partial alarm edits — wholesale replacement
            // is the supported pattern.
            for alarm in reminder.alarms ?? [] {
                reminder.removeAlarm(alarm)
            }
            for date in alarmDates {
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
        }

        try store.save(reminder, commit: commit)
        return true
    }

    /// Fetches a single reminder by its calendarItemIdentifier.
    func fetchReminder(calendarItemId: String) -> EKReminder? {
        store.calendarItem(withIdentifier: calendarItemId) as? EKReminder
    }

    /// Returns the `lastModifiedDate` of a reminder, for conflict resolution.
    func lastModified(calendarItemId: String) -> Date? {
        fetchReminder(calendarItemId: calendarItemId)?.lastModifiedDate
    }

}
