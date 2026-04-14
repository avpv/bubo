import EventKit
import Foundation

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
    static let remindersDataChanged = Notification.Name("AppleRemindersDataChanged")

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
        if let observer = storeChangedObserver {
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
            return try await store.requestFullAccessToReminders()
        } catch {
            print("Failed to request full Reminders access: \(error)")
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
        // Apple Reminders priority mapping:
        //   0 = none → medium (neutral default)
        //   1...4 = high (UI shows !!!)
        //   5 = medium (UI shows !!)
        //   6...9 = low (UI shows !)
        let priority: TaskPriority
        switch reminder.priority {
        case 1...4: priority = .high
        case 5: priority = .medium
        case 6...9: priority = .low
        default: priority = .medium // 0 (none) = neutral
        }

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

}
