import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "ExcludedOccurrenceStore")

// MARK: - Excluded Occurrence Store

/// Repository for recurrence-occurrence exclusions. Same repository
/// pattern as `LocalEventStore`: fresh context per operation, CloudKit
/// dedup via `UpsertReconciler`, errors surfaced through `lastError`
/// instead of silently logged.
@Observable
@MainActor
final class ExcludedOccurrenceStore: ExcludedOccurrenceStoring {
    private let container: ModelContainer
    private(set) var lastError: String?

    init(container: ModelContainer) {
        self.container = container
    }

    func loadAll() -> Set<String> {
        let context = ModelContext(container)
        do {
            let persisted = try context.fetch(FetchDescriptor<PersistedExcludedOccurrence>())
            lastError = nil
            return Set(persisted.map(\.occurrenceId))
        } catch {
            logger.error("Failed to load excluded occurrences: \(error)")
            lastError = "Load failed: \(error.localizedDescription)"
            return []
        }
    }

    func save(_ desired: Set<String>) {
        let context = ModelContext(container)
        let now = Date()
        do {
            try UpsertReconciler.reconcile(
                context: context,
                desired: Array(desired),
                desiredKey: { $0 },
                existingKey: \PersistedExcludedOccurrence.occurrenceId,
                updatedAt: \PersistedExcludedOccurrence.updatedAt,
                apply: { _, _ in /* no mutable fields beyond the key */ },
                makeNew: { id in PersistedExcludedOccurrence(occurrenceId: id, updatedAt: now) }
            )
            try context.save()
            lastError = nil
        } catch {
            logger.error("Failed to save excluded occurrences: \(error)")
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}
