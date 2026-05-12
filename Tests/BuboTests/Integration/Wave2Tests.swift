import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Wave 2 Tests
// Covers ObjectiveCorrelationClusterer and PathRelinking. MOEA/D-AWA
// and CMAMEEmitter were retired.

@Suite("Objective correlation clustering")
struct ObjectiveClusteringTests {
    @Test("highly correlated objectives merge into one cluster")
    func mergesCorrelated() {
        let names = ["A", "B", "C", "D"]
        // A and B are perfectly correlated; C and D independent.
        let rows: [[Double]] = [
            [0.1, 0.1, 0.5, 0.9],
            [0.9, 0.9, 0.2, 0.1],
            [0.5, 0.5, 0.8, 0.3],
            [0.3, 0.3, 0.4, 0.7],
        ]
        let assignment = ObjectiveCorrelationClusterer.cluster(
            names: names, rows: rows, threshold: 0.8
        )
        // Expect A+B merged into one cluster.
        let abIndex = assignment.clusterIndexOf["A"]
        #expect(abIndex == assignment.clusterIndexOf["B"])
    }

    @Test("uncorrelated objectives stay separate")
    func keepsUncorrelated() {
        let names = ["A", "B"]
        // Random-ish independent signals.
        let rows: [[Double]] = [
            [0.1, 0.9], [0.9, 0.1], [0.5, 0.5], [0.3, 0.7], [0.7, 0.3],
        ]
        let assignment = ObjectiveCorrelationClusterer.cluster(
            names: names, rows: rows, threshold: 0.95
        )
        #expect(assignment.clusterIndexOf["A"] != assignment.clusterIndexOf["B"])
    }

    @Test("aggregate averages cluster members")
    func aggregation() {
        let names = ["A", "B"]
        let rows: [[Double]] = [
            [0.9, 0.9], [0.1, 0.1],
        ]
        let assignment = ObjectiveCorrelationClusterer.cluster(
            names: names, rows: rows, threshold: 0.5
        )
        let aggregated = assignment.aggregate(objectives: ["A": 0.8, "B": 0.4])
        // A and B merged → single cluster with avg = 0.6.
        #expect(aggregated.count == 1)
        #expect(abs(aggregated[0] - 0.6) < 1e-9)
    }

    @Test("warmup returns trivial one-cluster-per-objective")
    func warmupTrivial() {
        let clusterer = ObjectiveCorrelationClusterer(
            config: .init(mergeThreshold: 0.5, emaDecay: 0.5, warmupSamples: 1000)
        )
        clusterer.observe(names: ["A", "B"], rows: [[0.1, 0.9], [0.5, 0.5]])
        let assignment = clusterer.currentClustering()
        #expect(assignment.clusters.count == 2)
    }
}

@Suite("Path Relinking")
struct PathRelinkingTests {
    @Test("identical genomes return the better parent")
    func identicalReturnsBetter() {
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: [
            OptimizerTestFixtures.makeEvent(id: "A")
        ])
        let chromo = ScheduleChromosome.random(context: ctx)
        var a = chromo
        a.rawFitness = 0.8
        a.fitness = 0.8
        var b = chromo
        b.rawFitness = 0.6
        b.fitness = 0.6
        let result = PathRelinking.relink(
            source: a,
            guide: b,
            context: ctx,
            evaluate: { _ in }
        )
        #expect(result.evaluationsPerformed == 0)
        #expect(result.best.rawFitness == 0.8)
    }

    @Test("walk evaluates at most maxSteps * diffSize candidates")
    func boundedEvaluations() {
        let events = (0..<4).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let a = ScheduleChromosome.random(context: ctx)
        var b = ScheduleChromosome.random(context: ctx)
        // Force guide slightly different by swapping first two genes' start times.
        if b.genes.count >= 2 {
            let tmp = b.genes[0].startTime
            b.genes[0] = b.genes[0].withStartTime(b.genes[1].startTime)
            b.genes[1] = b.genes[1].withStartTime(tmp)
        }
        var evalCount = 0
        _ = PathRelinking.relink(
            source: a,
            guide: b,
            context: ctx,
            evaluate: { chromo in
                evalCount += 1
                chromo.rawFitness = Double.random(in: 0...1)
                chromo.fitness = chromo.rawFitness
                chromo.needsEvaluation = false
            },
            mode: .forward,
            maxSteps: 4
        )
        #expect(evalCount <= 4 * 4)
    }
}

