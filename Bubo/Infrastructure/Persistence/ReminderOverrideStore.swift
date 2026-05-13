import Foundation
import SwiftData
import os

private let reminderOverrideLogger = Logger(subsystem: "com.avpv.Bubo", category: "ReminderOverrideStore")

// MARK: - Reminder Override Store

/// Repository for per-event reminder time overrides. Same repository
/// pattern as `LocalEventStore`.
@Observable
@MainActor
final class ReminderOverrideStore: ReminderOverrideStoring {
    private let container: ModelContainer
    private(set) var lastError: String?

    init(container: ModelContainer) {
        self.container = container
    }

    func loadAll() -> [String: [Int]] {
        let context = ModelContext(container)
        do {
            let persisted = try context.fetch(FetchDescriptor<PersistedReminderOverride>())
            lastError = nil
            let deduped = Dictionary(grouping: persisted, by: \.eventId)
                .compactMap { $1.max(by: { $0.updatedAt < $1.updatedAt }) }
            return Dictionary(uniqueKeysWithValues: deduped.map { ($0.eventId, $0.minutes) })
        } catch {
            reminderOverrideLogger.error("Failed to load reminder overrides: \(error)")
            lastError = "Load failed: \(error.localizedDescription)"
            return [:]
        }
    }

    func save(_ desired: [String: [Int]]) {
        let context = ModelContext(container)
        let now = Date()
        let items = desired.map { (key: $0.key, value: $0.value) }
        do {
            try UpsertReconciler.reconcile(
                context: context,
                desired: items,
                desiredKey: { $0.key },
                existingKey: \PersistedReminderOverride.eventId,
                updatedAt: \PersistedReminderOverride.updatedAt,
                apply: { row, item in
                    // Avoid a no-op `updatedAt` bump — would otherwise
                    // trigger a pointless CloudKit push to every device
                    // whenever a different field saves.
                    if row.minutes != item.value {
                        row.minutes = item.value
                        row.updatedAt = now
                    }
                },
                makeNew: { item in
                    PersistedReminderOverride(
                        eventId: item.key, minutes: item.value, updatedAt: now
                    )
                }
            )
            try context.save()
            lastError = nil
        } catch {
            reminderOverrideLogger.error("Failed to save reminder overrides: \(error)")
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}
