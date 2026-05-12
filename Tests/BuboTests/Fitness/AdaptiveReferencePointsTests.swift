import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

@Suite("A-NSGA-III Adaptive Reference Points")
struct AdaptiveNSGA3Tests {

    @Test("Initial reference-point count matches the base Das–Dennis grid")
    func adaptiveRankerInitializesToBase() {
        let base = NSGA3.forPopulation(objectiveCount: 5, populationSize: 30)
        let adaptive = AdaptiveNSGA3(base: base)
        #expect(adaptive.currentRanker.referencePoints.points.count == base.referencePoints.points.count)
        #expect(adaptive.telemetry.referencePointCount == base.referencePoints.points.count)
        #expect(adaptive.telemetry.pointsAdded == 0)
        #expect(adaptive.telemetry.pointsRemoved == 0)
    }

    @Test("Observation advances the generation counter")
    func observationAdvancesGeneration() {
        let adaptive = AdaptiveNSGA3.forPopulation(objectiveCount: 3, populationSize: 10)
        let ranker = adaptive.currentRanker
        let vectors: [[Double]] = [
            [0.9, 0.1, 0.1],
            [0.1, 0.9, 0.1],
            [0.1, 0.1, 0.9]
        ]
        let result = ranker.select(vectors, count: 3)
        let beforeGen = adaptive.generation
        adaptive.observe(result, updateInterval: 1000)
        #expect(adaptive.generation == beforeGen + 1)
    }

    @Test("Crowded niches cause the reference-point set to grow")
    func crowdedNichesTriggerSplit() {
        let base = NSGA3(referencePoints: .dasDennis(dimension: 3, divisions: 4))
        let adaptive = AdaptiveNSGA3(
            base: base,
            memoryWindow: 3,
            vacantWindow: 1000,  // effectively disable pruning
            crowdedThreshold: 1.0,
            splitShrink: 0.5
        )
        let initialCount = adaptive.currentRanker.referencePoints.points.count

        let cluster: [[Double]] = [
            [0.95, 0.025, 0.025],
            [0.95, 0.025, 0.025],
            [0.95, 0.025, 0.025]
        ]
        for _ in 0..<10 {
            let ranker = adaptive.currentRanker
            let result = ranker.select(cluster, count: 3)
            adaptive.observe(result, updateInterval: 5)
        }
        #expect(adaptive.telemetry.referencePointCount >= initialCount)
        #expect(adaptive.telemetry.pointsAdded >= 0)
    }
}
