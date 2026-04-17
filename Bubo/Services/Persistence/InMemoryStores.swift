import Foundation

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
