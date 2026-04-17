import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "LocalEventStore")

// MARK: - Local Event Store

/// Repository for user-created local events (non-EventKit). Isolates
/// `ReminderService` from SwiftData details — the service holds the
/// in-memory array, the store owns disk + CloudKit persistence.
///
/// Each operation opens a fresh `ModelContext`, the same pattern used by
/// `BacklogService` and `EventCache`. Mutations never touch
/// `container.mainContext` to avoid the threading hazards that cost us
/// v1.10.30–v1.10.41.
///
/// `lastError` is published so callers (Settings UI) can surface silent
/// persistence failures instead of losing data into `logger.error`.
@Observable
@MainActor
final class LocalEventStore {
    private let container: ModelContainer
    private(set) var lastError: String?

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Read

    /// Fetch all local events, collapsing CloudKit-introduced duplicates
    /// by picking the row with the latest `updatedAt` per `eventId`.
    func loadAll() -> [CalendarEvent] {
        let context = ModelContext(container)
        do {
            let persisted = try context.fetch(FetchDescriptor<PersistedLocalEvent>())
            lastError = nil
            let deduped = Dictionary(grouping: persisted, by: \.eventId)
                .compactMap { $1.max(by: { $0.updatedAt < $1.updatedAt }) }
            return deduped.map { $0.toCalendarEvent() }
        } catch {
            logger.error("Failed to load local events: \(error)")
            lastError = "Load failed: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Write

    /// Reconcile the persisted set with `desired`. Delegates to
    /// `UpsertReconciler` for the dedup + insert/update/delete pass.
    func save(_ desired: [CalendarEvent]) {
        let context = ModelContext(container)
        let now = Date()
        do {
            try UpsertReconciler.reconcile(
                context: context,
                desired: desired,
                desiredKey: \.id,
                existingKey: \PersistedLocalEvent.eventId,
                updatedAt: \PersistedLocalEvent.updatedAt,
                apply: { row, event in row.apply(event, updatedAt: now) },
                makeNew: { event in PersistedLocalEvent(from: event, updatedAt: now) }
            )
            try context.save()
            lastError = nil
        } catch {
            logger.error("Failed to save local events: \(error)")
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}
