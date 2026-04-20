import Foundation
import Testing
@testable import Bubo

@Suite("Schedule Conflict Graph")
struct ScheduleConflictGraphTests {

    // MARK: - Components

    @Test("Independent events produce distinct components")
    func independentEventsAreDistinctComponents() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [
                OptimizerTestFixtures.makeEvent(id: "a"),
                OptimizerTestFixtures.makeEvent(id: "b"),
                OptimizerTestFixtures.makeEvent(id: "c")
            ]
        )
        let graph = ScheduleConflictGraph.build(from: context)
        #expect(graph.componentCount == 3)
        let cids = Set(["a", "b", "c"].compactMap { graph.componentOf[$0] })
        #expect(cids.count == 3)
    }

    @Test("dependsOn chain collapses into one component")
    func dependsOnChainIsOneComponent() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let c = OptimizableEvent(id: "c", title: "c", duration: 3600, dependsOn: ["b"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b, c])
        let graph = ScheduleConflictGraph.build(from: context)
        #expect(graph.componentCount == 1)
        #expect(graph.componentOf["a"] == graph.componentOf["c"])
    }

    @Test("Shared participant couples events into one component")
    func sharedParticipantCouples() {
        let a = OptimizableEvent(id: "a", title: "a", duration: 3600, requiredParticipants: ["alice"])
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, requiredParticipants: ["alice"])
        let c = OptimizerTestFixtures.makeEvent(id: "c")
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b, c])
        let graph = ScheduleConflictGraph.build(from: context)
        #expect(graph.componentOf["a"] == graph.componentOf["b"])
        #expect(graph.componentOf["c"] != graph.componentOf["a"])
    }

    @Test("allComponents returns every member exactly once")
    func allComponentsEnumeratesMembers() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let c = OptimizerTestFixtures.makeEvent(id: "c")
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b, c])
        let graph = ScheduleConflictGraph.build(from: context)

        let buckets = graph.allComponents()
        let flat = buckets.flatMap { $0 }.sorted()
        #expect(flat == ["a", "b", "c"])
        // a and b chained → same bucket; c on its own.
        #expect(buckets.count == 2)
    }

    // MARK: - Precedence

    @Test("precedenceEdgeCount matches directPrecedes size")
    func precedenceEdgeCountMatchesDirectPrecedes() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let c = OptimizableEvent(id: "c", title: "c", duration: 3600, dependsOn: ["a", "b"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b, c])
        let graph = ScheduleConflictGraph.build(from: context)

        // 3 direct edges: a→b, a→c, b→c.
        #expect(graph.precedenceEdgeCount == 3)
        // Transitive: a reaches b and c; b reaches c.
        #expect(graph.precedes["a"]?.contains("c") == true)
        #expect(graph.precedes["b"]?.contains("c") == true)
    }

    @Test("maxChainDepth captures the deepest descendant count")
    func maxChainDepthIsNormalisedDeepest() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let c = OptimizableEvent(id: "c", title: "c", duration: 3600, dependsOn: ["b"])
        let d = OptimizableEvent(id: "d", title: "d", duration: 3600, dependsOn: ["c"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b, c, d])
        let graph = ScheduleConflictGraph.build(from: context)

        // a transitively reaches b, c, d → 3 descendants. Normalised by N=4 → 0.75.
        #expect(abs(graph.maxChainDepth - 0.75) < 1e-9)
    }

    // MARK: - Tightness

    @Test("precedenceTightness rewards tight back-to-back placement")
    func precedenceTightnessRewardsTight() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [
                OptimizerTestFixtures.makeEvent(id: "a"),
                OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
            ]
        )
        let graph = ScheduleConflictGraph.build(from: context)

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let tightGenes = [
            ScheduleGene(eventId: "a", title: "a", startTime: base, duration: 3600,
                         context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false),
            ScheduleGene(eventId: "b", title: "b", startTime: base.addingTimeInterval(3600), duration: 3600,
                         context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)
        ]
        let tightChromo = ScheduleChromosome(genes: tightGenes, needsEvaluation: true)
        #expect(graph.precedenceTightness(for: tightChromo) == 1.0)

        let looseGenes = [
            tightGenes[0],
            ScheduleGene(eventId: "b", title: "b", startTime: base.addingTimeInterval(48 * 3600), duration: 3600,
                         context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)
        ]
        let looseChromo = ScheduleChromosome(genes: looseGenes, needsEvaluation: true)
        #expect(graph.precedenceTightness(for: looseChromo) == 0.0)
    }

    // MARK: - Density

    @Test("conflictDensity normalises to [0, 1]")
    func conflictDensityStaysInRange() {
        let a = OptimizableEvent(id: "a", title: "a", duration: 3600, requiredParticipants: ["p"])
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, requiredParticipants: ["p"])
        let c = OptimizableEvent(id: "c", title: "c", duration: 3600, requiredParticipants: ["p"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b, c])
        let graph = ScheduleConflictGraph.build(from: context)

        // 3 events all sharing one participant → 3 pairs / 3 possible = 1.0
        #expect(graph.conflictDensity == 1.0)
    }

    // MARK: - Holder cache

    @Test("ConflictGraphHolder returns the same instance across calls")
    func holderCachesSingleInstance() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [OptimizerTestFixtures.makeEvent(id: "a")]
        )
        let holder = ConflictGraphHolder()
        let g1 = holder.get(for: context)
        let g2 = holder.get(for: context)
        // Structs don't have identity, so compare a stable property.
        #expect(g1.eventIds == g2.eventIds)
        #expect(g1.componentCount == g2.componentCount)
    }

    // MARK: - Preferred-hour bucketing

    @Test("Overlapping preferred-hour ranges still couple events into one component")
    func overlappingPreferredHoursCouple() {
        let a = OptimizableEvent(
            id: "a", title: "a", duration: 3600, preferredHourRange: 9...12
        )
        let b = OptimizableEvent(
            id: "b", title: "b", duration: 3600, preferredHourRange: 11...14
        )
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b])
        let graph = ScheduleConflictGraph.build(from: context)
        #expect(graph.componentOf["a"] == graph.componentOf["b"])
    }

    @Test("Non-overlapping preferred-hour ranges stay independent")
    func nonOverlappingPreferredHoursIndependent() {
        let a = OptimizableEvent(
            id: "a", title: "a", duration: 3600, preferredHourRange: 9...10
        )
        let b = OptimizableEvent(
            id: "b", title: "b", duration: 3600, preferredHourRange: 14...16
        )
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b])
        let graph = ScheduleConflictGraph.build(from: context)
        #expect(graph.componentOf["a"] != graph.componentOf["b"])
    }

    @Test("Events without preferredHourRange are skipped by the bucketed scan")
    func eventsWithoutRangeAreSkipped() {
        let a = OptimizableEvent(
            id: "a", title: "a", duration: 3600, preferredHourRange: 9...12
        )
        let b = OptimizerTestFixtures.makeEvent(id: "b")  // no range
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b])
        let graph = ScheduleConflictGraph.build(from: context)
        #expect(graph.componentOf["a"] != graph.componentOf["b"])
    }

    // MARK: - Reachability bitset

    @Test("precedesBitset matches the precedes dictionary")
    func precedesBitsetMatchesDict() {
        let a = OptimizerTestFixtures.makeEvent(id: "a")
        let b = OptimizableEvent(id: "b", title: "b", duration: 3600, dependsOn: ["a"])
        let c = OptimizableEvent(id: "c", title: "c", duration: 3600, dependsOn: ["b"])
        let context = OptimizerTestFixtures.makeContext(movableEvents: [a, b, c])
        let graph = ScheduleConflictGraph.build(from: context)

        let bitset = graph.precedesBitset
        #expect(bitset != nil)
        // a precedes b and c transitively; b precedes c; c precedes nothing.
        #expect(graph.transitivelyPrecedes("a", "b"))
        #expect(graph.transitivelyPrecedes("a", "c"))
        #expect(graph.transitivelyPrecedes("b", "c"))
        #expect(graph.transitivelyPrecedes("c", "a") == false)
    }

    @Test("Empty context produces no bitset")
    func emptyContextHasNoBitset() {
        let graph = ScheduleConflictGraph.build(from: OptimizerTestFixtures.makeContext())
        #expect(graph.precedesBitset == nil)
        #expect(graph.transitivelyPrecedes("ghost", "phantom") == false)
    }
}
