import XCTest
@testable import Bubo

// MARK: - Graph Performance Tests
//
// Baseline benchmarks for the graph-build and reachability paths
// touched by the Tier 1 graph performance work. These are XCTest
// `measure` blocks rather than Swift Testing so the standard
// XCTest performance result UI surfaces in Xcode.
//
// Targets are *relative* — these tests flag regressions, not
// absolute-time SLAs. CI runners vary too much to set hard wall-
// clock thresholds. Compare a PR's measurement to its base branch.

final class GraphPerformanceTests: XCTestCase {

    // MARK: - Fixtures

    /// Build a synthetic intent list of approximately `count` distinct
    /// intents. Deliberately mixes phases so the topological sort
    /// has to do non-trivial work.
    private func makeIntents(count: Int) -> [ScheduleIntent] {
        var out: [ScheduleIntent] = []
        var hour = 8
        for i in 0..<count {
            switch i % 8 {
            case 0: out.append(.noEventsBefore(hour: hour))
            case 1: out.append(.focusBlock(minutes: 60 + (i % 4) * 15))
            case 2: out.append(.lowEnergy)
            case 3: out.append(.morningPerson)
            case 4: out.append(.protectLunch())
            case 5: out.append(.batchMeetings())
            case 6: out.append(.includeBacklog)
            default: out.append(.prioritizeDeadlines())
            }
            hour = (hour + 1) % 18
        }
        return out
    }

    /// Build a synthetic movable-event list with realistic structure:
    /// some shared participants, dependency chains, preferred-hour
    /// ranges. Sized so the conflict-graph build has to exercise both
    /// the participant-index path and the bucketed hour-range scan.
    private func makeMovableEvents(count: Int) -> [OptimizableEvent] {
        var events: [OptimizableEvent] = []
        events.reserveCapacity(count)
        for i in 0..<count {
            let participants: [String]
            switch i % 5 {
            case 0: participants = ["alice"]
            case 1: participants = ["bob"]
            case 2: participants = ["alice", "bob"]
            case 3: participants = []
            default: participants = ["carol"]
            }
            let depends: [String] = i > 0 && i % 3 == 0
                ? ["event_\(i - 1)"]
                : []
            let range: ClosedRange<Int>? = i % 4 == 0
                ? (8 + i % 6)...(11 + i % 6)
                : nil
            events.append(OptimizableEvent(
                id: "event_\(i)",
                title: "Event \(i)",
                duration: 3600,
                requiredParticipants: participants,
                preferredHourRange: range,
                dependsOn: depends
            ))
        }
        return events
    }

    // MARK: - IntentGraph

    /// Cold builds at typical scale (~30 intents). Establishes the
    /// baseline cost of `build` + auto-resolution + conflict
    /// detection without any caching.
    func testIntentGraphBuildPerformance() {
        let intents = makeIntents(count: 30)
        measure {
            for _ in 0..<100 {
                _ = IntentGraph.build(from: intents)
            }
        }
    }

    /// Topological sort cost — the SwiftUI composer rebuild path.
    /// Builds the graph once, then measures `sortedIntents()` only.
    func testIntentGraphSortedIntentsPerformance() {
        let graph = IntentGraph.build(from: makeIntents(count: 30))
        measure {
            for _ in 0..<1000 {
                _ = graph.sortedIntents()
            }
        }
    }

    /// Reachability over all sources — the diagnostic path used by
    /// `IntentConflictDetector` and SCC tooling.
    func testIntentGraphReachabilityPerformance() {
        let graph = IntentGraph.build(from: makeIntents(count: 30))
        measure {
            for _ in 0..<200 {
                _ = graph.reachability()
            }
        }
    }

    // MARK: - IntentGraphCache

    /// Cache-warm path: 100 calls with the same input. Should be
    /// dominated by hash + lookup cost, not graph build cost.
    func testIntentGraphCacheWarmHitPerformance() {
        let cache = IntentGraphCache()
        let intents = makeIntents(count: 30)
        // Prime the cache.
        _ = cache.graph(for: intents)
        measure {
            for _ in 0..<1000 {
                _ = cache.graph(for: intents)
            }
        }
    }

    // MARK: - ScheduleConflictGraph

    /// Cold builds at typical schedule size (50 events with realistic
    /// participant overlap and dependency chains).
    func testScheduleConflictGraphBuildPerformance() {
        let events = makeMovableEvents(count: 50)
        measure {
            for _ in 0..<50 {
                _ = ScheduleConflictGraph.build(fromMovableEvents: events)
            }
        }
    }

    /// Tests the bucketed preferred-hour scan specifically by giving
    /// every event a preferred range — the path most affected by the
    /// sort+sweep optimization.
    func testScheduleConflictGraphHourBucketingPerformance() {
        let events = (0..<50).map { i in
            OptimizableEvent(
                id: "e_\(i)",
                title: "e_\(i)",
                duration: 3600,
                preferredHourRange: (8 + i % 6)...(11 + i % 6)
            )
        }
        measure {
            for _ in 0..<50 {
                _ = ScheduleConflictGraph.build(fromMovableEvents: events)
            }
        }
    }

    // MARK: - ReachabilityBitset

    /// Bitset query throughput. Builds a graph with deep dependency
    /// chains and measures repeated `transitivelyPrecedes` lookups.
    func testReachabilityBitsetQueryPerformance() {
        let events = makeMovableEvents(count: 50)
        let graph = ScheduleConflictGraph.build(fromMovableEvents: events)
        // Force the bitset build outside the measure block.
        _ = graph.transitivelyPrecedes("event_0", "event_1")
        measure {
            for _ in 0..<10_000 {
                _ = graph.transitivelyPrecedes("event_0", "event_30")
            }
        }
    }
}
