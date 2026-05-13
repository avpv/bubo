import XCTest
import SwiftData
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - UpsertReconciler Tests
//
// Covers the four scenarios the helper is supposed to guarantee on
// CloudKit-backed stores (no `@Attribute(.unique)` safety net, so bugs
// here show up as silent data corruption in production):
//
//   1. Insert — no existing rows, desired state has N items.
//   2. Update — existing row matches desired key; `apply` runs.
//   3. Delete — existing row exists but desired state dropped the key.
//   4. Dedup — multiple rows share a logical key; only the newest
//      `updatedAt` survives.
//
// Plus a mixed scenario that exercises all four paths in one reconcile.

@MainActor
final class UpsertReconcilerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedReminderOverride.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func fetchAll(_ context: ModelContext) throws -> [PersistedReminderOverride] {
        try context.fetch(FetchDescriptor<PersistedReminderOverride>(
            sortBy: [SortDescriptor(\.eventId)]
        ))
    }

    /// Run the same reconcile call `ReminderService.saveLocalRemindersOverrides`
    /// uses, against a caller-provided desired dict. Keeps the test focused
    /// on the helper, not on the service wiring.
    private func reconcile(
        context: ModelContext,
        desired: [String: [Int]],
        now: Date = Date()
    ) throws {
        let items = desired.map { (key: $0.key, value: $0.value) }
        try UpsertReconciler.reconcile(
            context: context,
            desired: items,
            desiredKey: { $0.key },
            existingKey: \PersistedReminderOverride.eventId,
            updatedAt: \PersistedReminderOverride.updatedAt,
            apply: { row, item in
                if row.minutes != item.value {
                    row.minutes = item.value
                    row.updatedAt = now
                }
            },
            makeNew: { item in
                PersistedReminderOverride(
                    eventId: item.key,
                    minutes: item.value,
                    updatedAt: now
                )
            }
        )
    }

    // MARK: - Insert

    func testInsertsWhenStoreIsEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        try reconcile(context: context, desired: ["a": [5], "b": [10, 30]])
        try context.save()

        let rows = try fetchAll(context)
        XCTAssertEqual(rows.map(\.eventId), ["a", "b"])
        XCTAssertEqual(rows[0].minutes, [5])
        XCTAssertEqual(rows[1].minutes, [10, 30])
    }

    // MARK: - Update

    func testUpdatesSurvivingRowInPlace() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        context.insert(PersistedReminderOverride(eventId: "a", minutes: [5], updatedAt: t0))
        try context.save()

        let t1 = t0.addingTimeInterval(60)
        try reconcile(context: context, desired: ["a": [15]], now: t1)
        try context.save()

        let rows = try fetchAll(context)
        XCTAssertEqual(rows.count, 1, "update must not create a new row")
        XCTAssertEqual(rows[0].minutes, [15])
        XCTAssertEqual(rows[0].updatedAt, t1, "updatedAt should bump when value changes")
    }

    func testUpdateWithSameValueDoesNotBumpUpdatedAt() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        context.insert(PersistedReminderOverride(eventId: "a", minutes: [5], updatedAt: t0))
        try context.save()

        try reconcile(context: context, desired: ["a": [5]], now: t0.addingTimeInterval(60))
        try context.save()

        let rows = try fetchAll(context)
        XCTAssertEqual(rows[0].updatedAt, t0, "unchanged value should leave updatedAt alone")
    }

    // MARK: - Delete

    func testDeletesRowWhenKeyIsNoLongerDesired() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        context.insert(PersistedReminderOverride(eventId: "a", minutes: [5]))
        context.insert(PersistedReminderOverride(eventId: "b", minutes: [10]))
        try context.save()

        try reconcile(context: context, desired: ["a": [5]])
        try context.save()

        let rows = try fetchAll(context)
        XCTAssertEqual(rows.map(\.eventId), ["a"], "b should be deleted — no longer desired")
    }

    // MARK: - Dedup

    func testCollapsesDuplicatesKeepingLatestUpdatedAt() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Three rows share the logical key "a". CloudKit merge window
        // could have introduced this — dedup must pick the newest.
        context.insert(PersistedReminderOverride(eventId: "a", minutes: [5], updatedAt: t0))
        context.insert(PersistedReminderOverride(
            eventId: "a", minutes: [15], updatedAt: t0.addingTimeInterval(120)
        ))
        context.insert(PersistedReminderOverride(
            eventId: "a", minutes: [10], updatedAt: t0.addingTimeInterval(60)
        ))
        try context.save()

        // Reconcile with the same value — shouldn't rewrite, should
        // just collapse to the newest row.
        try reconcile(context: context, desired: ["a": [15]])
        try context.save()

        let rows = try fetchAll(context)
        XCTAssertEqual(rows.count, 1, "duplicates must collapse to a single row")
        XCTAssertEqual(rows[0].minutes, [15], "winner is the newest updatedAt")
    }

    func testCollapsesDuplicatesAndDeletesWhenUndesired() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        context.insert(PersistedReminderOverride(eventId: "a", minutes: [5], updatedAt: t0))
        context.insert(PersistedReminderOverride(
            eventId: "a", minutes: [10], updatedAt: t0.addingTimeInterval(60)
        ))
        try context.save()

        // Desired state drops "a" entirely — both duplicates must go.
        try reconcile(context: context, desired: [:])
        try context.save()

        let rows = try fetchAll(context)
        XCTAssertTrue(rows.isEmpty, "all duplicates of an undesired key must be deleted")
    }

    // MARK: - Mixed

    func testMixedScenarioExercisesAllFourPaths() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // "keep" — matching row, updated value
        context.insert(PersistedReminderOverride(eventId: "keep", minutes: [5], updatedAt: t0))
        // "remove" — row exists but not desired anymore
        context.insert(PersistedReminderOverride(eventId: "remove", minutes: [10], updatedAt: t0))
        // "dup" — two rows, desired with updated value
        context.insert(PersistedReminderOverride(eventId: "dup", minutes: [1], updatedAt: t0))
        context.insert(PersistedReminderOverride(
            eventId: "dup", minutes: [2], updatedAt: t0.addingTimeInterval(60)
        ))
        try context.save()

        try reconcile(
            context: context,
            desired: [
                "keep": [25],
                "dup": [99],
                "new": [30],
            ],
            now: t0.addingTimeInterval(300)
        )
        try context.save()

        let rows = try fetchAll(context)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.eventId, $0) })

        XCTAssertEqual(Set(byId.keys), ["keep", "dup", "new"])
        XCTAssertEqual(byId["keep"]?.minutes, [25])
        XCTAssertEqual(byId["dup"]?.minutes, [99])
        XCTAssertEqual(byId["new"]?.minutes, [30])
        XCTAssertNil(byId["remove"])
    }

    // MARK: - Empty Desired

    func testEmptyDesiredOnEmptyStoreIsNoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        try reconcile(context: context, desired: [:])
        try context.save()

        XCTAssertTrue(try fetchAll(context).isEmpty)
    }

    func testEmptyDesiredWipesStore() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        context.insert(PersistedReminderOverride(eventId: "a", minutes: [5]))
        context.insert(PersistedReminderOverride(eventId: "b", minutes: [10]))
        try context.save()

        try reconcile(context: context, desired: [:])
        try context.save()

        XCTAssertTrue(try fetchAll(context).isEmpty)
    }
}
