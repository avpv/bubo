import XCTest
import SwiftData
@testable import Bubo

// MARK: - BacklogTaskStore Tests
//
// Exercises both implementations of `BacklogTaskStoring` against the
// same scenario matrix: the SwiftData-backed production store (against
// an in-memory `ModelContainer`) and the pure-Swift `InMemoryBacklogTaskStore`.
// Running identical assertions on both catches contract drift — a bug
// in one but not the other fails here.

@MainActor
final class BacklogTaskStoreTests: XCTestCase {

    // MARK: - Fixtures

    private func task(
        _ id: String,
        title: String = "",
        duration: Int = 30,
        priority: TaskPriority = .medium
    ) -> BacklogTask {
        BacklogTask(
            id: id,
            title: title.isEmpty ? id : title,
            durationMinutes: duration,
            priority: priority
        )
    }

    private func makeSwiftDataStore() throws -> BacklogTaskStore {
        let container = try ModelContainer(
            for: PersistedBacklogTask.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return BacklogTaskStore(container: container)
    }

    private func makeInMemoryStore() -> InMemoryBacklogTaskStore {
        InMemoryBacklogTaskStore()
    }

    // MARK: - Contract Verification

    /// Run the same test body against both implementations.
    private func runContract(
        _ body: (_ store: any BacklogTaskStoring) throws -> Void,
        line: UInt = #line
    ) throws {
        try body(makeSwiftDataStore())
        try body(makeInMemoryStore())
    }

    func testEmptyStoreReturnsEmptyLoad() throws {
        try runContract { store in
            XCTAssertTrue(store.loadAll().isEmpty)
        }
    }

    func testUpsertInsertsNewRows() throws {
        try runContract { store in
            store.upsert(self.task("a"), at: 0)
            store.upsert(self.task("b"), at: 1)
            XCTAssertEqual(store.loadAll().map(\.id), ["a", "b"])
        }
    }

    func testUpsertReplacesExistingById() throws {
        try runContract { store in
            store.upsert(self.task("a", title: "Alpha"), at: 0)
            store.upsert(self.task("a", title: "Alpha v2"), at: 0)
            let loaded = store.loadAll()
            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded[0].title, "Alpha v2")
        }
    }

    func testDeleteRemovesById() throws {
        try runContract { store in
            store.upsert(self.task("a"), at: 0)
            store.upsert(self.task("b"), at: 1)
            store.delete(id: "a")
            XCTAssertEqual(store.loadAll().map(\.id), ["b"])
        }
    }

    func testDeleteIsNoOpForUnknownId() throws {
        try runContract { store in
            store.upsert(self.task("a"), at: 0)
            store.delete(id: "missing")
            XCTAssertEqual(store.loadAll().map(\.id), ["a"])
        }
    }

    func testReorderUpdatesSortOrderForAffectedRows() throws {
        try runContract { store in
            // Seed three rows with explicit sortOrder.
            store.upsert(self.task("a"), at: 0)
            store.upsert(self.task("b"), at: 1)
            store.upsert(self.task("c"), at: 2)

            // Swap: new order [c, a, b]. Reorder from index 0 onwards.
            let newOrder = [self.task("c"), self.task("a"), self.task("b")]
            store.reorder(fromIndex: 0, tasks: newOrder)

            XCTAssertEqual(store.loadAll().map(\.id), ["c", "a", "b"])
        }
    }

    func testReplaceAllAligns() throws {
        try runContract { store in
            store.upsert(self.task("a"), at: 0)
            store.upsert(self.task("b"), at: 1)
            store.upsert(self.task("c"), at: 2)

            store.replaceAll(with: [self.task("x"), self.task("y")])
            XCTAssertEqual(store.loadAll().map(\.id), ["x", "y"])
        }
    }

    func testReconcilePreservesDiskRowsWhenMergeReturnsSame() throws {
        try runContract { store in
            let a = self.task("a")
            store.upsert(a, at: 0)

            // Merge is identity — no disk mutation expected.
            let merged = store.reconcile { disk in disk }
            XCTAssertEqual(merged.map(\.id), ["a"])
        }
    }

    func testReconcileAppliesMergeWinner() throws {
        try runContract { store in
            let disk = self.task("a", title: "Old")
            store.upsert(disk, at: 0)

            let merged = store.reconcile { _ in
                self.task("a", title: "New")
            }
            XCTAssertEqual(merged[0].title, "New")

            // Verify the win was written back.
            let reloaded = store.loadAll()
            XCTAssertEqual(reloaded[0].title, "New")
        }
    }

    // MARK: - Color tag persistence

    func testColorTagSurvivesUpsertRoundtrip() throws {
        try runContract { store in
            var t = self.task("a")
            t.colorTag = .blue
            store.upsert(t, at: 0)

            let loaded = store.loadAll()
            XCTAssertEqual(loaded.first?.colorTag, .blue)
        }
    }

    func testMissingColorTagDecodesAsNil() throws {
        try runContract { store in
            store.upsert(self.task("a"), at: 0)
            XCTAssertNil(store.loadAll().first?.colorTag)
        }
    }
}
