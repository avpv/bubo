import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "AppleReminders")

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
            // having to poll a static EventKit property.
            NotificationCenter.default.post(name: Self.authorizationDidChange, object: nil)
            return granted
        } catch {
            logger.error("Failed to request full Reminders access: \(error)")
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

    // MARK: - Convert to BacklogTask

    /// Converts an EKReminder into a BacklogTask suitable for the Bubo backlog.
    func toBacklogTask(_ reminder: EKReminder, defaultDuration: Int = 60) -> BacklogTask {
        let priority = Self.buboPriority(fromAppleReminders: reminder.priority)

        let deadline: Date?
        if let dueDateComponents = reminder.dueDateComponents {
            deadline = Calendar.current.date(from: dueDateComponents)
        } else {
            deadline = nil
        }

        return BacklogTask(
            id: "reminder_\(reminder.calendarItemIdentifier)",
            title: reminder.title ?? "Untitled",
            durationMinutes: defaultDuration,
            priority: priority,
            deadline: deadline,
            context: reminder.calendar.title,
            createdAt: reminder.creationDate ?? Date()
        )
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

        // Field-by-field diff — skip the save if nothing actually changed.
        var didChange = false
        if reminder.title != task.title { reminder.title = task.title; didChange = true }
        if reminder.priority != newPriority { reminder.priority = newPriority; didChange = true }
        if reminder.dueDateComponents != newDueComponents {
            reminder.dueDateComponents = newDueComponents
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

    /// Sets just the due-date components of a reminder.  Used by the Bubo
    /// scheduling writeback — `scheduledDate` replaces the reminder's due
    /// date so iPhone users see the time slot Bubo assigned the task.
    /// Pass `nil` to clear the due date. Returns `true` if anything actually
    /// changed; callers can skip logging when nothing needed writing.
    @discardableResult
    func updateReminderDueDate(calendarItemId: String, date: Date?) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: calendarItemId) as? EKReminder else {
            throw NSError(
                domain: "AppleRemindersService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Reminder not found for due-date update."]
            )
        }
        let newComponents: DateComponents? = date.map(Self.dueDateComponents(from:))
        guard reminder.dueDateComponents != newComponents else { return false }
        reminder.dueDateComponents = newComponents
        try store.save(reminder, commit: true)
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

    // MARK: - Priority Mapping (static — pure functions, testable)

    /// Maps Bubo TaskPriority to Apple Reminders integer priority.
    ///   high → 1 (!!!)   medium → 5 (!!)   low → 9 (!)
    static func appleRemindersPriority(from priority: TaskPriority) -> Int {
        switch priority {
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }

    /// Inverse mapping: Apple Reminders integer priority → Bubo TaskPriority.
    ///   0 (none) → medium (neutral default)
    ///   1...4    → high (UI shows !!!)
    ///   5        → medium (UI shows !!)
    ///   6...9    → low (UI shows !)
    static func buboPriority(fromAppleReminders raw: Int) -> TaskPriority {
        switch raw {
        case 1...4: return .high
        case 5: return .medium
        case 6...9: return .low
        default: return .medium // 0 = none
        }
    }

    // MARK: - Due Date Components (preserve date-only vs datetime granularity)

    /// Returns DateComponents suitable for `EKReminder.dueDateComponents`.
    /// If the deadline is exactly midnight local time, returns date-only
    /// components (year/month/day). This preserves the distinction Apple
    /// Reminders makes between "due today" vs "due today at 3:00 PM".
    static func dueDateComponents(from date: Date) -> DateComponents {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let hasMeaningfulTime = (comps.hour ?? 0) != 0
            || (comps.minute ?? 0) != 0
            || (comps.second ?? 0) != 0

        if hasMeaningfulTime {
            return cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }
        return cal.dateComponents([.year, .month, .day], from: date)
    }
}
