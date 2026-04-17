import Foundation

// MARK: - Store Protocols
//
// Repository abstractions that let `ReminderService` and tests depend on
// behaviour rather than on `SwiftData`. The concrete CloudKit-backed
// types in this folder conform; an `InMemory*` variant lives alongside
// each protocol for tests that don't need real persistence.
//
// Keeping the protocols here (rather than next to each concrete store)
// makes the surface visible at a glance and prevents the "wait, which
// type is the contract" problem when there are eventually multiple
// implementations per protocol.

// MARK: Local Events

/// Persisted-store contract for user-created local events.
@MainActor
protocol LocalEventStoring: AnyObject {
    /// Last failure surface for the UI. `nil` after a successful op.
    var lastError: String? { get }

    /// Fetch every persisted local event, with CloudKit-introduced
    /// duplicates collapsed by `updatedAt`.
    func loadAll() -> [CalendarEvent]

    /// Reconcile the persisted set with `desired` — insert / update /
    /// delete to converge.
    func save(_ desired: [CalendarEvent])
}

// MARK: Excluded Occurrences

/// Persisted-store contract for excluded recurrence occurrence IDs.
@MainActor
protocol ExcludedOccurrenceStoring: AnyObject {
    var lastError: String? { get }

    func loadAll() -> Set<String>
    func save(_ desired: Set<String>)
}

// MARK: Reminder Overrides

/// Persisted-store contract for per-event reminder time overrides.
@MainActor
protocol ReminderOverrideStoring: AnyObject {
    var lastError: String? { get }

    func loadAll() -> [String: [Int]]
    func save(_ desired: [String: [Int]])
}
