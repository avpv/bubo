import Foundation

// MARK: - Fetched Reminder

/// Value-type projection of an Apple Reminder that `RemindersSyncService`
/// actually uses. Pulling only these two fields out of `EKReminder`
/// keeps the sync service free of EventKit types, so it can be driven
/// against a `FakeRemindersEventSource` in tests — the real
/// `EKReminder` class can't be constructed without a `EKEventStore`.
struct FetchedReminder: Sendable, Equatable {
    let calendarItemId: String
    let task: BacklogTask
}

// MARK: - Reminders Event Source

/// Protocol abstraction over `AppleRemindersService` so
/// `RemindersSyncService` can be driven with a fake in tests. Mirrors
/// `CalendarEventSource` in shape — `hasAccess` as an instance property
/// plus a handful of verbs. Notification names (`remindersDataChanged`,
/// `authorizationDidChange`) stay on `AppleRemindersService` as static
/// topics; tests post them directly to trigger observers.
@MainActor
protocol RemindersEventSource: AnyObject {
    var hasAccess: Bool { get }

    /// Fetch incomplete reminders from the given lists (empty = all),
    /// converted into the value-type `FetchedReminder`. The default
    /// duration is applied to any reminder without an explicit estimate.
    func fetchIncompleteTasks(
        fromListIds: [String],
        defaultDuration: Int
    ) async -> [FetchedReminder]

    /// Mark an existing reminder as completed. Idempotent — calling on
    /// an already-completed reminder is a no-op in the concrete impl.
    func completeReminder(calendarItemId: String) throws

    /// Create a new reminder from a `BacklogTask`. Returns the
    /// newly-assigned `calendarItemIdentifier` so the caller can store
    /// it on the owning task and dedup on next import.
    func createReminder(
        from task: BacklogTask,
        inListId: String?
    ) throws -> String

    /// Push field updates (title, priority, deadline, context) to an
    /// existing reminder. Concrete implementations do field-level
    /// diffing and return `true` only when a save actually happened.
    @discardableResult
    func updateReminder(calendarItemId: String, from task: BacklogTask) throws -> Bool

    /// Push a due-date change plus the set of alarm fire-dates. Same
    /// diff-then-save semantics as `updateReminder`. The caller is
    /// responsible for choosing which alarms to fire — the source just
    /// installs whatever absolute dates it's given. An empty `alarmDates`
    /// clears all alarms; a `nil` `dueDate` clears the due slot too.
    @discardableResult
    func updateReminderSchedule(
        calendarItemId: String,
        dueDate: Date?,
        alarmDates: [Date]
    ) throws -> Bool

    /// Apply many schedule updates as a single transaction — saves each
    /// reminder with `commit: false` and flushes once at the end. Used by
    /// the settings-change sweep so toggling alarm policy on a backlog of
    /// 50 scheduled tasks produces one EventKit commit, not 50. Each
    /// update goes through the same diff-then-skip logic as the single
    /// variant; the return value counts reminders that actually changed.
    @discardableResult
    func applyScheduleUpdates(
        _ updates: [ScheduleUpdate]
    ) throws -> Int

    func deleteReminder(calendarItemId: String) throws
}

/// Plain value carrying everything needed for one schedule writeback.
/// Sits at the protocol level so the fake and the real source agree on
/// the shape without dragging EventKit types into the test target.
struct ScheduleUpdate: Equatable, Sendable {
    let calendarItemId: String
    let dueDate: Date?
    let alarmDates: [Date]
}

// MARK: AppleRemindersService conformance

extension AppleRemindersService: RemindersEventSource {
    var hasAccess: Bool { AppleRemindersService.hasAccess }

    func fetchIncompleteTasks(
        fromListIds: [String],
        defaultDuration: Int
    ) async -> [FetchedReminder] {
        let reminders = await fetchIncompleteReminders(fromListIds: fromListIds)
        return reminders.map { reminder in
            FetchedReminder(
                calendarItemId: reminder.calendarItemIdentifier,
                task: toBacklogTask(reminder, defaultDuration: defaultDuration)
            )
        }
    }
}
