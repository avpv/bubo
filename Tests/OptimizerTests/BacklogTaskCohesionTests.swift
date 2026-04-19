import XCTest
@testable import Bubo

final class BacklogTaskCohesionTests: XCTestCase {

    // MARK: Score

    func testScoreReturnsZeroForMisalignedTasks() {
        let a = task("A", context: "backend", period: .morning,
                     priority: .high, duration: 25,
                     deadline: day(+1))
        let b = task("B", context: "design", period: .evening,
                     priority: .low, duration: 120,
                     deadline: day(+30))
        XCTAssertEqual(BacklogTaskCohesion.score(a, b), 0)
    }

    func testSameContextAddsItsWeight() {
        let a = task("A", context: "backend", duration: 25)
        let b = task("B", context: "backend", duration: 200) // duration differs enough to skip that bucket
        // context=3.0, priority default .medium == .medium = 1.0, duration ratio 0.125 → skip, deadline both nil → 0.5.
        XCTAssertEqual(BacklogTaskCohesion.score(a, b), 3.0 + 1.0 + 0.5, accuracy: 0.001)
    }

    func testContextMatchIsCaseInsensitive() {
        let a = task("A", context: "Backend", duration: 25)
        let b = task("B", context: "backend", duration: 300)
        XCTAssertGreaterThan(BacklogTaskCohesion.score(a, b), 0)
    }

    func testEmptyContextDoesNotScore() {
        let a = task("A", context: "")
        let b = task("B", context: "")
        // Two empty contexts must NOT count as matching — that would
        // group every un-tagged task together.
        XCTAssertLessThan(BacklogTaskCohesion.score(a, b), BacklogTaskCohesion.Weights.default.sameContext)
    }

    func testDurationWithinRatioBucketCounts() {
        // 25 and 50 → ratio 0.5, on the boundary → counts.
        let a = task("A", duration: 25)
        let b = task("B", duration: 50)
        let s = BacklogTaskCohesion.score(a, b)
        XCTAssertGreaterThanOrEqual(s, BacklogTaskCohesion.Weights.default.comparableDuration)
    }

    func testDeadlineProximityCountsForNearbyDeadlines() {
        let a = task("A", deadline: day(+1))
        let b = task("B", deadline: day(+3))
        let s = BacklogTaskCohesion.score(a, b)
        XCTAssertGreaterThanOrEqual(s, BacklogTaskCohesion.Weights.default.nearbyDeadline)
    }

    func testCustomWeightsOverrideDefaults() {
        var w = BacklogTaskCohesion.Weights.default
        w.sameContext = 10.0
        let a = task("A", context: "proj")
        let b = task("B", context: "proj")
        XCTAssertGreaterThanOrEqual(BacklogTaskCohesion.score(a, b, weights: w), 10.0)
    }

    // MARK: Pick

    func testPickReturnsOnlyAnchorWhenMaxIsOne() {
        let anchor = task("A", context: "backend")
        let b = task("B", context: "backend")
        let pack = BacklogTaskCohesion.pick(from: [anchor, b], anchor: anchor, maxCohort: 1)
        XCTAssertEqual(pack.map(\.title), ["A"])
    }

    func testPickDropsZeroScoreCandidates() {
        let anchor = task("A", context: "backend", priority: .high,
                          duration: 25, deadline: day(+1))
        let matched = task("B", context: "backend", priority: .high,
                           duration: 25, deadline: day(+1))
        // Everything differs, no empty-deadline alignment either.
        let mismatched = task("C", context: "design", period: .evening,
                              priority: .low, duration: 300,
                              deadline: day(+60))
        let pool = [anchor, matched, mismatched]
        let pack = BacklogTaskCohesion.pick(from: pool, anchor: anchor, maxCohort: 4)
        XCTAssertEqual(pack.map(\.title), ["A", "B"])
    }

    func testPickPrefersHigherScore() {
        let anchor = task("A", context: "backend", period: .morning,
                          priority: .high, duration: 25)
        let strong = task("strong", context: "backend", period: .morning,
                          priority: .high, duration: 25)
        let weak = task("weak", priority: .high)  // only priority matches + both-nil deadlines
        let pool = [anchor, weak, strong]
        let pack = BacklogTaskCohesion.pick(from: pool, anchor: anchor, maxCohort: 3)
        XCTAssertEqual(pack.map(\.title), ["A", "strong", "weak"])
    }

    func testPickTieBreaksByBacklogOrder() {
        let anchor = task("A", context: "backend")
        let first = task("first", context: "backend")
        let second = task("second", context: "backend")
        // Both score identically to anchor. Earlier in pool should win.
        let pack = BacklogTaskCohesion.pick(from: [anchor, first, second], anchor: anchor, maxCohort: 2)
        XCTAssertEqual(pack.map(\.title), ["A", "first"])
    }

    func testPickExcludesAnchorFromCohort() {
        let anchor = task("A", context: "backend")
        let other = task("B", context: "backend")
        let pack = BacklogTaskCohesion.pick(from: [anchor, anchor, other], anchor: anchor, maxCohort: 4)
        XCTAssertEqual(pack.filter { $0.id == anchor.id }.count, 1)
    }

    // MARK: Build Pack

    func testBuildPackReturnsEmptyForEmptyPool() {
        let pack = BacklogTaskCohesion.buildPack(from: [], maxTasks: 4, contextFilter: nil)
        XCTAssertTrue(pack.isEmpty)
    }

    func testBuildPackHonoursExplicitContextMatchingTwoOrMore() {
        let a = task("A", context: "backend")
        let b = task("B", context: "backend")
        let c = task("C", context: "design")
        let pack = BacklogTaskCohesion.buildPack(
            from: [a, b, c], maxTasks: 4, contextFilter: "backend"
        )
        XCTAssertEqual(pack.map(\.title), ["A", "B"])
    }

    func testBuildPackWithLoneContextUsesItAsCohesionAnchor() {
        // "design" matches only C. The pack should anchor on C and
        // pull the most similar peers from the whole pool.
        let a = task("A", context: "backend", priority: .low)
        let b = task("B", context: "backend", priority: .low)
        let c = task("C", context: "design", priority: .low)
        let pack = BacklogTaskCohesion.buildPack(
            from: [a, b, c], maxTasks: 3, contextFilter: "design"
        )
        XCTAssertEqual(pack.first?.title, "C")
        XCTAssertTrue(pack.count >= 2, "cohort should grow around the lone match")
    }

    func testBuildPackWithoutFilterFallsBackToTopTaskCohesion() {
        let anchor = task("A", context: "backend")
        let match = task("B", context: "backend")
        let outsider = task("C", context: "ops")
        let pack = BacklogTaskCohesion.buildPack(
            from: [anchor, outsider, match], maxTasks: 3, contextFilter: nil
        )
        XCTAssertEqual(pack.first?.title, "A")
        // `match` scores higher against anchor than `outsider`.
        XCTAssertEqual(pack.dropFirst().first?.title, "B")
    }

    func testBuildPackUnknownFilterFallsBackToTopTask() {
        let a = task("A", context: "backend")
        let b = task("B", context: "backend")
        let pack = BacklogTaskCohesion.buildPack(
            from: [a, b], maxTasks: 2, contextFilter: "does-not-exist"
        )
        XCTAssertEqual(pack.first?.title, "A")
    }

    func testBuildPackRespectsMaxTasksCap() {
        let pool = (0..<6).map { i in task("T\(i)", context: "same") }
        let pack = BacklogTaskCohesion.buildPack(
            from: pool, maxTasks: 3, contextFilter: "same"
        )
        XCTAssertEqual(pack.count, 3)
        XCTAssertEqual(pack.map(\.title), ["T0", "T1", "T2"])
    }

    // MARK: Helpers

    private func task(
        _ title: String,
        context: String? = nil,
        period: Period? = nil,
        priority: TaskPriority = .medium,
        duration: Int = 60,
        deadline: Date? = nil
    ) -> BacklogTask {
        BacklogTask(
            id: title, title: title,
            durationMinutes: duration, priority: priority,
            deadline: deadline, storyPoints: nil,
            context: context, preferredPeriod: period
        )
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    }
}
