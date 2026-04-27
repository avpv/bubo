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

// MARK: Event Attribute Overrides

/// User-set attributes that ride alongside an external (Apple Calendar)
/// event without modifying the EventKit row. Mirrors the two fields
/// `CalendarEvent` exposes to the editor for non-local events.
struct EventAttributeOverride: Equatable, Sendable {
    var colorTag: EventColorTag?
    var context: String?

    /// True when both fields are unset — the override carries no signal
    /// and can be deleted instead of persisted.
    var isEmpty: Bool {
        colorTag == nil && (context?.isEmpty ?? true)
    }
}

/// Persisted-store contract for per-event color/context overrides on
/// external events. Same shape as `ReminderOverrideStoring`.
@MainActor
protocol EventAttributeOverrideStoring: AnyObject {
    var lastError: String? { get }

    func loadAll() -> [String: EventAttributeOverride]
    func save(_ desired: [String: EventAttributeOverride])
}

// MARK: Backlog Tasks

/// Persisted-store contract for backlog tasks. The mutation surface is
/// richer than the other three stores because `BacklogService` needs
/// targeted per-row writes (incremental persistence) rather than the
/// diff-based "save the whole collection" pattern. Each mutation touches
/// only the rows that actually changed — CloudKit-friendly and avoids
/// rewriting the whole table on every keystroke.
@MainActor
protocol BacklogTaskStoring: AnyObject {
    /// All persisted tasks, sorted by `sortOrder`.
    func loadAll() -> [BacklogTask]

    /// Insert or update a single task, setting its `sortOrder`. If a row
    /// with the same `taskId` already exists, it's updated in place —
    /// defensive against CloudKit merges landing a row just before a
    /// local insert fires.
    func upsert(_ task: BacklogTask, at sortOrder: Int)

    /// Delete by `taskId`. No-op if no row matches.
    func delete(id: String)

    /// Rewrite `sortOrder` for rows at or after `fromIndex` to match the
    /// in-memory array. Touched-rows-only.
    func reorder(fromIndex: Int, tasks: [BacklogTask])

    /// Full reconcile — align the persisted set to `tasks` exactly.
    /// Collapses duplicates and deletes rows not in the live set. Safety
    /// net for tests and future bulk import paths.
    func replaceAll(with tasks: [BacklogTask])

    /// Walk every persisted row in order, ask `merging` for the winning
    /// snapshot (typically a `BacklogTask.merged(local:remote:)` call
    /// against the caller's pre-import in-memory state), write back the
    /// winner if it differs from disk, and return the merged list.
    /// Single save at the end — used by the CloudKit post-import path
    /// where cost-per-import matters.
    func reconcile(merging: (_ disk: BacklogTask) -> BacklogTask) -> [BacklogTask]
}
