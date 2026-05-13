import Foundation
import SwiftData
import os
import BuboDomain

private let eventAttrOverrideLogger = Logger(subsystem: "com.avpv.Bubo", category: "EventAttributeOverrideStore")

// MARK: - Event Attribute Override Store

/// Repository for per-event color/context overrides on external (Apple
/// Calendar) events. Same repository pattern as `ReminderOverrideStore`.
@Observable
@MainActor
final class EventAttributeOverrideStore: EventAttributeOverrideStoring {
    private let container: ModelContainer
    private(set) var lastError: String?

    init(container: ModelContainer) {
        self.container = container
    }

    func loadAll() -> [String: EventAttributeOverride] {
        let context = ModelContext(container)
        do {
            let persisted = try context.fetch(FetchDescriptor<PersistedEventAttributeOverride>())
            lastError = nil
            let deduped = Dictionary(grouping: persisted, by: \.eventId)
                .compactMap { $1.max(by: { $0.updatedAt < $1.updatedAt }) }
            return Dictionary(uniqueKeysWithValues: deduped.map {
                (
                    $0.eventId,
                    EventAttributeOverride(
                        colorTag: $0.colorTagRaw.flatMap { EventColorTag(rawValue: $0) },
                        context: $0.context
                    )
                )
            })
        } catch {
            eventAttrOverrideLogger.error("Failed to load event attribute overrides: \(error)")
            lastError = "Load failed: \(error.localizedDescription)"
            return [:]
        }
    }

    func save(_ desired: [String: EventAttributeOverride]) {
        let context = ModelContext(container)
        let now = Date()
        let items = desired.map { (key: $0.key, value: $0.value) }
        do {
            try UpsertReconciler.reconcile(
                context: context,
                desired: items,
                desiredKey: { $0.key },
                existingKey: \PersistedEventAttributeOverride.eventId,
                updatedAt: \PersistedEventAttributeOverride.updatedAt,
                apply: { row, item in
                    let newRaw = item.value.colorTag?.rawValue
                    if row.colorTagRaw != newRaw || row.context != item.value.context {
                        row.colorTagRaw = newRaw
                        row.context = item.value.context
                        row.updatedAt = now
                    }
                },
                makeNew: { item in
                    PersistedEventAttributeOverride(
                        eventId: item.key,
                        colorTag: item.value.colorTag,
                        context: item.value.context,
                        updatedAt: now
                    )
                }
            )
            try context.save()
            lastError = nil
        } catch {
            eventAttrOverrideLogger.error("Failed to save event attribute overrides: \(error)")
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}
