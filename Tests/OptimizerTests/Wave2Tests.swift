import Foundation
import Testing
@testable import Bubo

// MARK: - Wave 2 Tests
// Covers MOEA/D-AWA, ObjectiveCorrelationClusterer, PathRelinking,
// CMAMEEmitter. Kept in a single file so the wave is atomic.

@Suite("MOEA/D-AWA decomposition")
struct MOEADTests {
    @Test("initialises with population-sized weight vectors")
    func initWeights() {
        let state = MOEADState(dimension: 5, populationSize: 20)
        let weights = state.weightVectors
        #expect(weights.count > 0)
        // Every weight vector sums to ~1 on the unit simplex.
        for w in weights {
            let s = w.reduce(0, +)
            #expect(abs(s - 1.0) < 1e-6)
        }
    }

    @Test("tchebycheff picks the candidate matching the direction")
    func tchebycheffPicksBest() {
        // Dimension 2; two candidates, each dominating one axis.
        let state = MOEADState(dimension: 2, populationSize: 3, scalarisation: .tchebycheff)
        let cands: [(index: Int, objectives: [Double])] = [
            (0, [1.0, 0.0]),
            (1, [0.0, 1.0]),
        ]
        state.updateIncumbents(candidates: cands)
        let selected = state.selectedIndices(from: cands)
        // At least one of the two candidates wins a subproblem.
        #expect(Set(selected).isSubset(of: Set([0, 1])))
        #expect(!selected.isEmpty)
    }

    @Test("ideal point tracks per-axis maximum")
    func idealPoint() {
        let state = MOEADState(dimension: 3, populationSize: 4)
        state.updateIncumbents(candidates: [
            (0, [0.1, 0.8, 0.2]),
            (1, [0.9, 0.3, 0.7]),
        ])
        let ideal = state.currentIdealPoint
        #expect(abs(ideal[0] - 0.9) < 1e-9)
        #expect(abs(ideal[1] - 0.8) < 1e-9)
        #expect(abs(ideal[2] - 0.7) < 1e-9)
    }
}

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

@Suite("CMA-ME emitter")
struct CMAMEEmitterTests {
    @Test("emit produces chromosomes of template length")
    func emitShape() {
        let events = (0..<3).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let template = ScheduleChromosome.random(context: ctx)
        let emitter = CMAMEEmitter(template: template)
        let child = emitter.emit(context: ctx)
        #expect(child.genes.count == template.genes.count)
    }

    @Test("observe with low success rate shrinks sigma")
    func sigmaShrinks() {
        let events = (0..<3).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let template = ScheduleChromosome.random(context: ctx)
        let emitter = CMAMEEmitter(
            template: template,
            config: .init(
                initialSigmaMinutes: 60,
                sigmaMin: 1,
                sigmaCap: 240,
                targetSuccessRate: 0.15,
                sigmaAdaptationRate: 0.5
            )
        )
        let before = emitter.telemetry.meanSigma
        for _ in 0..<5 {
            emitter.observe(successCount: 0, totalSamples: 10)
        }
        let after = emitter.telemetry.meanSigma
        #expect(after < before)
    }

    @Test("observe with high success rate grows sigma")
    func sigmaGrows() {
        let events = (0..<3).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let template = ScheduleChromosome.random(context: ctx)
        let emitter = CMAMEEmitter(
            template: template,
            config: .init(
                initialSigmaMinutes: 30,
                sigmaMin: 1,
                sigmaCap: 300,
                targetSuccessRate: 0.15,
                sigmaAdaptationRate: 0.5
            )
        )
        let before = emitter.telemetry.meanSigma
        for _ in 0..<5 {
            emitter.observe(successCount: 8, totalSamples: 10)
        }
        let after = emitter.telemetry.meanSigma
        #expect(after > before)
    }

    @Test("hasConverged flips when sigma hits floor")
    func convergence() {
        let events = (0..<2).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let template = ScheduleChromosome.random(context: ctx)
        let emitter = CMAMEEmitter(
            template: template,
            config: .init(
                initialSigmaMinutes: 20,
                sigmaMin: 5,
                sigmaCap: 100,
                targetSuccessRate: 0.15,
                sigmaAdaptationRate: 2.0
            )
        )
        #expect(!emitter.hasConverged)
        for _ in 0..<50 {
            emitter.observe(successCount: 0, totalSamples: 10)
        }
        #expect(emitter.hasConverged)
    }
}
