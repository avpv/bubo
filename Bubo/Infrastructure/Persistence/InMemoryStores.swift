import Foundation
import BuboDomain

// MARK: - In-Memory Store Doubles
//
// Test doubles for the three persistence-store protocols. Live in the
// app target (not a separate test bundle) because:
//   1. They need to see the protocols, which are `internal`.
//   2. SwiftUI previews can use them too — a `ReminderService` driven by
//      InMemory stores avoids creating real .store files on disk every
//      time you tweak a layout.
//
// Keep these dumb. They don't simulate CloudKit merge windows, latency,
// or schema migration — that's `UpsertReconciler`'s job. They simulate
// only the "key → row" identity model the protocols expose.

@MainActor
final class InMemoryLocalEventStore: LocalEventStoring {
    private(set) var lastError: String? = nil
    private var events: [String: CalendarEvent] = [:]

    init(seed: [CalendarEvent] = []) {
        for event in seed { events[event.id] = event }
    }

    func loadAll() -> [CalendarEvent] {
        Array(events.values)
    }

    func save(_ desired: [CalendarEvent]) {
        events.removeAll()
        for event in desired { events[event.id] = event }
    }
}

@MainActor
final class InMemoryExcludedOccurrenceStore: ExcludedOccurrenceStoring {
    private(set) var lastError: String? = nil
    private var ids: Set<String> = []

    init(seed: Set<String> = []) {
        ids = seed
    }

    func loadAll() -> Set<String> { ids }

    func save(_ desired: Set<String>) { ids = desired }
}

@MainActor
final class InMemoryReminderOverrideStore: ReminderOverrideStoring {
    private(set) var lastError: String? = nil
    private var overrides: [String: [Int]] = [:]

    init(seed: [String: [Int]] = [:]) {
        overrides = seed
    }

    func loadAll() -> [String: [Int]] { overrides }

    func save(_ desired: [String: [Int]]) { overrides = desired }
}

@MainActor
final class InMemoryEventAttributeOverrideStore: EventAttributeOverrideStoring {
    private(set) var lastError: String? = nil
    private var overrides: [String: EventAttributeOverride] = [:]

    init(seed: [String: EventAttributeOverride] = [:]) {
        overrides = seed
    }

    func loadAll() -> [String: EventAttributeOverride] { overrides }

    func save(_ desired: [String: EventAttributeOverride]) { overrides = desired }
}

@MainActor
final class InMemoryBacklogTaskStore: BacklogTaskStoring {
    private struct Row {
        var task: BacklogTask
        var sortOrder: Int
    }

    /// Keyed by taskId so `upsert` is O(1) and `delete` is unambiguous.
    /// A sorted array is rebuilt from this for `loadAll`.
    private var rows: [String: Row] = [:]

    init(seed: [BacklogTask] = []) {
        for (index, task) in seed.enumerated() {
            rows[task.id] = Row(task: task, sortOrder: index)
        }
    }

    func loadAll() -> [BacklogTask] {
        rows.values
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.task)
    }

    func upsert(_ task: BacklogTask, at sortOrder: Int) {
        rows[task.id] = Row(task: task, sortOrder: sortOrder)
    }

    func delete(id: String) {
        rows.removeValue(forKey: id)
    }

    func reorder(fromIndex: Int, tasks: [BacklogTask]) {
        guard fromIndex >= 0, fromIndex < tasks.count else { return }
        for (offset, task) in tasks[fromIndex...].enumerated() {
            let expected = fromIndex + offset
            if var row = rows[task.id] {
                row.sortOrder = expected
                rows[task.id] = row
            }
        }
    }

    func replaceAll(with tasks: [BacklogTask]) {
        rows.removeAll()
        for (index, task) in tasks.enumerated() {
            rows[task.id] = Row(task: task, sortOrder: index)
        }
    }

    func reconcile(merging: (_ disk: BacklogTask) -> BacklogTask) -> [BacklogTask] {
        let sorted = rows.values.sorted { $0.sortOrder < $1.sortOrder }
        var merged: [BacklogTask] = []
        merged.reserveCapacity(sorted.count)
        for row in sorted {
            let winner = merging(row.task)
            merged.append(winner)
            if winner != row.task {
                rows[winner.id] = Row(task: winner, sortOrder: row.sortOrder)
                // If the merged ID differs from the disk ID (shouldn't
                // in practice, merged rule never changes id), remove old.
                if winner.id != row.task.id {
                    rows.removeValue(forKey: row.task.id)
                }
            }
        }
        return merged
    }
}
