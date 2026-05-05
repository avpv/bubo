import Foundation

// MARK: - Fake Reminders Event Source

/// Test / preview double for `RemindersEventSource`. Same design as
/// `FakeCalendarEventSource`: record every call, expose the underlying
/// store as `tasks` so fetches return canned slices and mutations land
/// locally. Lives in the app target so SwiftUI previews can use it too.
@MainActor
final class FakeRemindersEventSource: RemindersEventSource {
    enum Invocation: Equatable {
        case fetch(listIds: [String], defaultDuration: Int)
        case complete(calendarItemId: String)
        case create(taskId: String, listId: String?)
        case update(calendarItemId: String, taskId: String)
        case updateSchedule(calendarItemId: String, dueDate: Date?, alarmDates: [Date])
        case delete(calendarItemId: String)
    }

    // MARK: - Configurable state

    var hasAccess: Bool
    /// Reminder fixtures that will be returned by `fetchIncompleteTasks`.
    /// Keyed by `calendarItemId` so mutations (complete / delete / update)
    /// can target them.
    private var store: [String: BacklogTask]
    /// When non-nil, the next mutation throws this error once and clears.
    var nextErrorForMutation: Error?

    // MARK: - Recorded calls

    private(set) var invocations: [Invocation] = []

    init(
        hasAccess: Bool = true,
        seed: [(calendarItemId: String, task: BacklogTask)] = []
    ) {
        self.hasAccess = hasAccess
        self.store = Dictionary(uniqueKeysWithValues: seed.map { ($0.calendarItemId, $0.task) })
    }

    // MARK: - Conformance

    func fetchIncompleteTasks(
        fromListIds: [String],
        defaultDuration: Int
    ) async -> [FetchedReminder] {
        invocations.append(.fetch(listIds: fromListIds, defaultDuration: defaultDuration))
        return store.map { FetchedReminder(calendarItemId: $0.key, task: $0.value) }
    }

    func completeReminder(calendarItemId: String) throws {
        invocations.append(.complete(calendarItemId: calendarItemId))
        try throwIfQueued()
        store.removeValue(forKey: calendarItemId)
    }

    func createReminder(from task: BacklogTask, inListId: String?) throws -> String {
        invocations.append(.create(taskId: task.id, listId: inListId))
        try throwIfQueued()
        let id = "fake-\(UUID().uuidString)"
        store[id] = task
        return id
    }

    @discardableResult
    func updateReminder(calendarItemId: String, from task: BacklogTask) throws -> Bool {
        invocations.append(.update(calendarItemId: calendarItemId, taskId: task.id))
        try throwIfQueued()
        let existed = store[calendarItemId] != nil
        store[calendarItemId] = task
        return existed
    }

    @discardableResult
    func updateReminderSchedule(
        calendarItemId: String,
        dueDate: Date?,
        alarmDates: [Date]
    ) throws -> Bool {
        invocations.append(.updateSchedule(
            calendarItemId: calendarItemId,
            dueDate: dueDate,
            alarmDates: alarmDates
        ))
        try throwIfQueued()
        guard var task = store[calendarItemId] else { return false }
        task.deadline = dueDate
        store[calendarItemId] = task
        return true
    }

    func deleteReminder(calendarItemId: String) throws {
        invocations.append(.delete(calendarItemId: calendarItemId))
        try throwIfQueued()
        store.removeValue(forKey: calendarItemId)
    }

    // MARK: - Helpers

    private func throwIfQueued() throws {
        if let error = nextErrorForMutation {
            nextErrorForMutation = nil
            throw error
        }
    }
}
