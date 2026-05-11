import Foundation
import SwiftData

// MARK: - UpsertReconciler

/// Reconciles a SwiftData-backed collection with a desired in-memory
/// state in a single pass: collapses duplicate rows that CloudKit's
/// merge window may have introduced, updates survivors in place, inserts
/// missing rows, and deletes rows whose logical key is no longer desired.
///
/// Exists because three different save paths in `ReminderService`
/// (`PersistedLocalEvent`, `PersistedExcludedOccurrence`,
/// `PersistedReminderOverride`) were running the exact same routine by
/// hand. Centralising it means bugs get fixed once, and the tests under
/// `Tests/BuboTests/UpsertReconcilerTests.swift` exercise all four
/// scenarios (insert / update / delete / dedup) on an in-memory container.
///
/// Not thread-safe — the caller is expected to serialise via its own
/// actor (MainActor for `ReminderService`, a dedicated actor for
/// background services) and pass in a fresh `ModelContext`. Matches the
/// "fresh context per operation" convention used by `BacklogService` and
/// `EventCache`.
enum UpsertReconciler {

    /// Run one reconcile pass.
    ///
    /// - Parameters:
    ///   - context: a fresh `ModelContext` bound to the target container.
    ///     The caller is responsible for `context.save()` — this function
    ///     stages inserts/updates/deletes but does not commit, so a
    ///     caller can compose multiple reconciles in one transaction.
    ///   - desired: the in-memory items that should end up persisted.
    ///   - desiredKey: logical key extractor for an item.
    ///   - existingKey: key path on the persistence model that stores
    ///     the same logical key. Used both for matching and for grouping
    ///     duplicate rows.
    ///   - updatedAt: key path to the `Date` field used to pick the
    ///     winner when duplicate rows share a key. Newest wins.
    ///   - apply: mutate the surviving row to reflect the desired state.
    ///     Called even when nothing has changed — implementations should
    ///     be defensive about whether they bump `updatedAt`.
    ///   - makeNew: build a fresh model for an item that has no surviving
    ///     row. The new model is `context.insert`-ed before return.
    ///
    /// - Throws: whatever `context.fetch` throws.
    static func reconcile<Model: PersistentModel, Key: Hashable, Item>(
        context: ModelContext,
        desired: [Item],
        desiredKey: (Item) -> Key,
        existingKey: KeyPath<Model, Key>,
        updatedAt: KeyPath<Model, Date>,
        apply: (Model, Item) -> Void,
        makeNew: (Item) -> Model
    ) throws {
        let existing = try context.fetch(FetchDescriptor<Model>())
        let grouped = Dictionary(grouping: existing) { $0[keyPath: existingKey] }

        // Build a quick-lookup of desired items by key. Duplicate desired
        // keys collapse by last-write-wins on the input order — callers
        // should deduplicate their input if that matters.
        var desiredByKey: [Key: Item] = [:]
        desiredByKey.reserveCapacity(desired.count)
        for item in desired {
            desiredByKey[desiredKey(item)] = item
        }

        // Walk existing rows: collapse duplicates keeping the newest,
        // then either mark for upsert or delete the survivor outright if
        // the key is no longer desired.
        var survivors: [Key: Model] = [:]
        survivors.reserveCapacity(grouped.count)
        for (key, rows) in grouped {
            let sorted = rows.sorted { $0[keyPath: updatedAt] > $1[keyPath: updatedAt] }
            for duplicate in sorted.dropFirst() {
                context.delete(duplicate)
            }
            guard let keeper = sorted.first else { continue }
            if desiredByKey[key] != nil {
                survivors[key] = keeper
            } else {
                context.delete(keeper)
            }
        }

        // Upsert the desired state over the survivor map.
        for (key, item) in desiredByKey {
            if let row = survivors[key] {
                apply(row, item)
            } else {
                context.insert(makeNew(item))
            }
        }
    }
}
