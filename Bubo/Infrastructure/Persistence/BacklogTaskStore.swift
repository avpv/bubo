import Foundation
import SwiftData
import os
import BuboDomain

private let backlogTaskStoreLogger = Logger(subsystem: "com.avpv.Bubo", category: "BacklogTaskStore")

// MARK: - Backlog Task Store

/// SwiftData-backed implementation of `BacklogTaskStoring`. Extracted
/// from `BacklogService` so the service can focus on orchestration
/// (CloudKit reconcile merge rules, NotificationCenter posting, task
/// lifecycle) while the persistence primitives live here.
///
/// Fresh `ModelContext` per operation, same convention as
/// `LocalEventStore` / `EventCache`. Never touches `mainContext` — that
/// was the root cause of the v1.10.30 through v1.10.41 regressions.
@MainActor
final class BacklogTaskStore: BacklogTaskStoring {

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Load

    func loadAll() -> [BacklogTask] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        do {
            return try context.fetch(descriptor).map { $0.toBacklogTask() }
        } catch {
            backlogTaskStoreLogger.error("Failed to load backlog tasks: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Targeted Mutations

    func upsert(_ task: BacklogTask, at sortOrder: Int) {
        let context = ModelContext(container)
        if let existing = fetchOne(taskId: task.id, context: context) {
            existing.apply(task, sortOrder: sortOrder)
        } else {
            context.insert(PersistedBacklogTask(from: task, sortOrder: sortOrder))
        }
        save(context: context)
    }

    func delete(id: String) {
        let context = ModelContext(container)
        guard let row = fetchOne(taskId: id, context: context) else { return }
        context.delete(row)
        save(context: context)
    }

    func reorder(fromIndex: Int, tasks: [BacklogTask]) {
        guard fromIndex >= 0, fromIndex < tasks.count else { return }
        let context = ModelContext(container)
        let affected = tasks[fromIndex...]
        for (offset, task) in affected.enumerated() {
            let expectedOrder = fromIndex + offset
            guard let row = fetchOne(taskId: task.id, context: context) else { continue }
            if row.sortOrder != expectedOrder {
                row.sortOrder = expectedOrder
            }
        }
        save(context: context)
    }

    func replaceAll(with tasks: [BacklogTask]) {
        let context = ModelContext(container)
        let existing = (try? context.fetch(FetchDescriptor<PersistedBacklogTask>())) ?? []

        // Collapse CloudKit-merge-window duplicates: keep the first seen
        // row per taskId, delete the rest.
        var byId: [String: PersistedBacklogTask] = [:]
        for row in existing {
            if byId[row.taskId] == nil {
                byId[row.taskId] = row
            } else {
                context.delete(row)
            }
        }

        let liveIds = Set(tasks.map(\.id))
        for (id, row) in byId where !liveIds.contains(id) {
            context.delete(row)
            byId.removeValue(forKey: id)
        }

        for (index, task) in tasks.enumerated() {
            if let row = byId[task.id] {
                row.apply(task, sortOrder: index)
            } else {
                context.insert(PersistedBacklogTask(from: task, sortOrder: index))
            }
        }

        save(context: context)
    }

    // MARK: - CloudKit Reconcile

    func reconcile(merging: (_ disk: BacklogTask) -> BacklogTask) -> [BacklogTask] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }

        var merged: [BacklogTask] = []
        merged.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            let disk = row.toBacklogTask()
            let winner = merging(disk)
            merged.append(winner)

            // Write the winner back only when it differs from disk so
            // we don't dirty rows that didn't actually change.
            if winner != disk {
                row.apply(winner, sortOrder: index)
            }
        }
        save(context: context)
        return merged
    }

    // MARK: - Helpers

    private func fetchOne(taskId: String, context: ModelContext) -> PersistedBacklogTask? {
        var descriptor = FetchDescriptor<PersistedBacklogTask>(
            predicate: #Predicate { $0.taskId == taskId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func save(context: ModelContext) {
        do {
            try context.save()
        } catch {
            backlogTaskStoreLogger.error("Failed to save backlog context: \(error.localizedDescription)")
        }
    }
}
