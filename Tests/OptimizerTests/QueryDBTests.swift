import Foundation
import Testing
@testable import Bubo

@Suite("QueryDB dependency tracking")
struct QueryDBTests {

    // MARK: - Basic memoization

    @Test("Repeated query reuses the cached result without rebuilding")
    func cachedQueryDoesNotRebuild() {
        let db = QueryDB<Int>()
        let queryName = QueryKey("test", "answer")
        let inputKey = QueryKey("test", "x")
        db.setInput(inputKey)

        var buildCount = 0
        func run() -> Int {
            db.query(queryName) { tracker in
                tracker.read(inputKey)
                buildCount += 1
                return 42
            }
        }

        #expect(run() == 42)
        #expect(buildCount == 1)
        #expect(run() == 42)
        #expect(buildCount == 1, "Cached call should skip build")
    }

    // MARK: - Invalidation by dependency

    @Test("Mutating a touched input invalidates the cache")
    func invalidationOnTouchedInput() {
        let db = QueryDB<String>()
        let queryName = QueryKey("test", "concat")
        let inputA = QueryKey("test", "a")
        let inputB = QueryKey("test", "b")
        db.setInput(inputA)
        db.setInput(inputB)

        var buildCount = 0
        func run() -> String {
            db.query(queryName) { tracker in
                tracker.read(inputA)
                tracker.read(inputB)
                buildCount += 1
                return "ab"
            }
        }

        _ = run()
        #expect(buildCount == 1)

        // Bump inputA → cached entry sees a stale revision and
        // rebuilds.
        db.setInput(inputA)
        _ = run()
        #expect(buildCount == 2)
    }

    @Test("Mutating an untouched input does NOT invalidate the cache")
    func untouchedInputDoesNotInvalidate() {
        let db = QueryDB<String>()
        let queryName = QueryKey("test", "onlyTouchesA")
        let inputA = QueryKey("test", "a")
        let inputB = QueryKey("test", "b")
        db.setInput(inputA)
        db.setInput(inputB)

        var buildCount = 0
        func run() -> String {
            db.query(queryName) { tracker in
                tracker.read(inputA)  // only A
                buildCount += 1
                return "a-only"
            }
        }

        _ = run()
        #expect(buildCount == 1)

        // Bump inputB → unrelated to this query; cache stays warm.
        db.setInput(inputB)
        _ = run()
        #expect(buildCount == 1, "Untouched-input change must not invalidate")
    }

    // MARK: - Multi-query isolation

    @Test("Two queries with disjoint dep sets invalidate independently")
    func disjointQueriesAreIsolated() {
        let db = QueryDB<Int>()
        let qX = QueryKey("test", "x")
        let qY = QueryKey("test", "y")
        let inputX = QueryKey("test", "in_x")
        let inputY = QueryKey("test", "in_y")
        db.setInput(inputX)
        db.setInput(inputY)

        var buildsX = 0
        var buildsY = 0
        func runX() -> Int {
            db.query(qX) { t in
                t.read(inputX); buildsX += 1; return 1
            }
        }
        func runY() -> Int {
            db.query(qY) { t in
                t.read(inputY); buildsY += 1; return 2
            }
        }

        _ = runX(); _ = runY()
        #expect(buildsX == 1 && buildsY == 1)

        db.setInput(inputX)
        _ = runX(); _ = runY()
        // X rebuilt, Y stayed cached.
        #expect(buildsX == 2)
        #expect(buildsY == 1)
    }

    // MARK: - invalidateAll

    @Test("invalidateAll forces every query to rebuild")
    func invalidateAllForcesRebuild() {
        let db = QueryDB<Int>()
        let q = QueryKey("test", "q")
        let input = QueryKey("test", "i")
        db.setInput(input)

        var builds = 0
        _ = db.query(q) { t in t.read(input); builds += 1; return 1 }
        _ = db.query(q) { t in t.read(input); builds += 1; return 1 }
        #expect(builds == 1)

        db.invalidateAll()
        _ = db.query(q) { t in t.read(input); builds += 1; return 1 }
        #expect(builds == 2)
    }

    // MARK: - Diagnostics

    @Test("cachedCount reflects entries currently held")
    func cachedCountReflectsEntries() {
        let db = QueryDB<Int>()
        let input = QueryKey("test", "i")
        db.setInput(input)

        #expect(db.cachedCount == 0)
        _ = db.query(QueryKey("test", "a")) { t in t.read(input); return 1 }
        _ = db.query(QueryKey("test", "b")) { t in t.read(input); return 2 }
        #expect(db.cachedCount == 2)
    }
}
