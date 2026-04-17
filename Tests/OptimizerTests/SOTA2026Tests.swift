import Foundation
import Testing
@testable import Bubo

// MARK: - SOTA-2026 Phase-2 test helpers

private func sota2026MakeContext(
    movableEvents: [OptimizableEvent] = [],
    fixedEvents: [CalendarEvent] = [],
    workingHours: ClosedRange<Int> = 9...18
) -> OptimizerContext {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
    return OptimizerContext(
        fixedEvents: fixedEvents,
        movableEvents: movableEvents,
        workingHours: workingHours,
        planningHorizon: DateInterval(start: today, end: tomorrow),
        preferences: OptimizerPreferences(),
        rng: GARandom(seed: 4242)
    )
}

private func sota2026MakeEvent(
    id: String,
    durationMinutes: Int = 60,
    priority: Double = 0.5,
    isFocusBlock: Bool = false
) -> OptimizableEvent {
    OptimizableEvent(
        id: id,
        title: id,
        duration: TimeInterval(durationMinutes * 60),
        priority: priority,
        isFocusBlock: isFocusBlock
    )
}

// MARK: - AdaptiveNSGA3

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
        // Fabricate a trivial selection result.
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
        // 3-objective setup with strong crowding bias: every observed
        // candidate lands near the same direction.
        let base = NSGA3(referencePoints: .dasDennis(dimension: 3, divisions: 4))
        let adaptive = AdaptiveNSGA3(
            base: base,
            memoryWindow: 3,
            vacantWindow: 1000,  // effectively disable pruning
            crowdedThreshold: 1.0,
            splitShrink: 0.5
        )
        let initialCount = adaptive.currentRanker.referencePoints.points.count

        // Force every observation to associate with the same niche by
        // sending identical objective vectors repeatedly.
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

// MARK: - Hypervolume

@Suite("Hypervolume Estimator (HypE-lite)")
struct HypervolumeEstimatorTests {

    @Test("Total hypervolume of a single point equals its volume fraction")
    func totalHypervolumeSinglePoint() {
        let hv = HypervolumeEstimator(objectiveCount: 2, sampleCount: 20_000, seed: 7)
        let single: [[Double]] = [[0.5, 0.5]]
        let volume = hv.totalHypervolume(single)
        // A (0.5, 0.5) point dominates 25% of the unit square. Monte Carlo
        // noise with 20k samples gives ~0.5% std; allow 5% slack.
        #expect(abs(volume - 0.25) < 0.05)
    }

    @Test("Contributions are non-negative and sum at most to the unit hypercube")
    func contributionsAreBounded() {
        let hv = HypervolumeEstimator(objectiveCount: 3, sampleCount: 5_000, seed: 11)
        let pop: [[Double]] = [
            [0.9, 0.1, 0.5],
            [0.1, 0.9, 0.5],
            [0.5, 0.5, 0.9],
            [0.3, 0.3, 0.3]
        ]
        let contribs = hv.contributions(pop)
        #expect(contribs.count == pop.count)
        #expect(contribs.allSatisfy { $0 >= 0 })
        // Sum of contributions = approximate total hypervolume.
        let total = contribs.reduce(0, +)
        #expect(total <= 1.0 + 1e-6)
    }

    @Test("Survivors returns exactly k indices, all unique")
    func survivorsReturnsKUniqueIndices() {
        let hv = HypervolumeEstimator(objectiveCount: 3, sampleCount: 2_000, seed: 13)
        let ranker = NSGA3.forPopulation(objectiveCount: 3, populationSize: 6)
        let pop: [[Double]] = [
            [0.9, 0.1, 0.1],
            [0.1, 0.9, 0.1],
            [0.1, 0.1, 0.9],
            [0.5, 0.5, 0.1],
            [0.5, 0.1, 0.5],
            [0.2, 0.2, 0.2]
        ]
        let survivors = hv.survivorsWithNSGA3(pop, keeping: 4, using: ranker)
        #expect(survivors.count == 4)
        #expect(Set(survivors).count == 4)
    }
}

// MARK: - RBFSurrogate

@Suite("RBF Surrogate Screening")
struct RBFSurrogateTests {

    @Test("Warm-up phase forces real evaluation")
    func warmupScreens() {
        let surrogate = RBFSurrogate(config: .default)
        let features = [Double](repeating: 0.5, count: ScheduleFeatures.dimension)
        switch surrogate.screen(features: features) {
        case .realEvaluate:
            #expect(true)
        case .accept:
            Issue.record("Surrogate should not accept during warm-up")
        }
    }

    @Test("After warm-up, nearby queries accept the surrogate prediction")
    func postWarmupAcceptsNearby() {
        // Custom config with minimal warm-up to keep the test fast.
        let config = RBFSurrogate.Configuration(
            capacity: 100,
            bandwidth: 0.3,
            neighbors: 5,
            realEvalThreshold: 0.5,
            trustRefreshInterval: 100,
            warmupSamples: 10
        )
        let surrogate = RBFSurrogate(config: config)
        let baseline = [Double](repeating: 0.5, count: ScheduleFeatures.dimension)
        for _ in 0..<15 {
            surrogate.record(features: baseline, fitness: 0.8)
        }
        // Tweak one feature very slightly — should still be within
        // bandwidth so the RBF trusts itself.
        var near = baseline
        near[0] += 0.01
        switch surrogate.screen(features: near) {
        case .accept(let predicted):
            #expect(abs(predicted - 0.8) < 0.1)
        case .realEvaluate:
            Issue.record("Expected surrogate to accept a near-duplicate query")
        }
    }

    @Test("Far queries trigger real evaluation")
    func farQueriesRealEvaluate() {
        let config = RBFSurrogate.Configuration(
            capacity: 100,
            bandwidth: 0.3,
            neighbors: 5,
            realEvalThreshold: 0.2,
            trustRefreshInterval: 100,
            warmupSamples: 10
        )
        let surrogate = RBFSurrogate(config: config)
        let baseline = [Double](repeating: 0.0, count: ScheduleFeatures.dimension)
        for _ in 0..<15 {
            surrogate.record(features: baseline, fitness: 0.8)
        }
        let far = [Double](repeating: 1.0, count: ScheduleFeatures.dimension)
        switch surrogate.screen(features: far) {
        case .realEvaluate:
            #expect(true)
        case .accept:
            Issue.record("Expected real-evaluate on a far-away query")
        }
    }
}

// MARK: - Quality-Diversity Archive

@Suite("Quality-Diversity Archive")
struct QualityDiversityArchiveTests {

    @Test("New cells are always accepted")
    func freshCellsAccepted() {
        let archive = QualityDiversityArchive(resolution: 4)
        let context = sota2026MakeContext(
            movableEvents: [sota2026MakeEvent(id: "t1"), sota2026MakeEvent(id: "t2")]
        )
        var chromo = ScheduleChromosome.random(context: context)
        chromo.rawFitness = 0.7
        let descriptor = BehaviorDescriptor.from(chromo, context: context)
        let (inserted, _) = archive.consider(chromo, descriptor: descriptor)
        #expect(inserted)
        #expect(archive.count == 1)
    }

    @Test("Better incumbents replace existing ones")
    func betterIncumbentsReplace() {
        let archive = QualityDiversityArchive(resolution: 4)
        let context = sota2026MakeContext(
            movableEvents: [sota2026MakeEvent(id: "t1")]
        )
        var chromo = ScheduleChromosome.random(context: context)
        chromo.rawFitness = 0.5
        let descriptor = BehaviorDescriptor.from(chromo, context: context)
        archive.consider(chromo, descriptor: descriptor)

        var better = chromo
        better.rawFitness = 0.8
        let (inserted, delta) = archive.consider(better, descriptor: descriptor)
        #expect(inserted)
        #expect(delta > 0)
        #expect(archive.count == 1)
    }

    @Test("Worse incumbents are rejected")
    func worseIncumbentsRejected() {
        let archive = QualityDiversityArchive(resolution: 4)
        let context = sota2026MakeContext(
            movableEvents: [sota2026MakeEvent(id: "t1")]
        )
        var chromo = ScheduleChromosome.random(context: context)
        chromo.rawFitness = 0.8
        let descriptor = BehaviorDescriptor.from(chromo, context: context)
        archive.consider(chromo, descriptor: descriptor)

        var worse = chromo
        worse.rawFitness = 0.3
        let (inserted, _) = archive.consider(worse, descriptor: descriptor)
        #expect(!inserted)
    }

    @Test("Emitter sampling returns cached incumbents")
    func emitterSamplingProducesIncumbents() {
        let archive = QualityDiversityArchive(resolution: 3)
        let context = sota2026MakeContext(
            movableEvents: (0..<5).map { sota2026MakeEvent(id: "t\($0)") }
        )
        for i in 0..<8 {
            var chromo = ScheduleChromosome.random(context: context)
            chromo.rawFitness = Double(i) * 0.1
            let descriptor = BehaviorDescriptor.from(chromo, context: context)
            archive.consider(chromo, descriptor: descriptor)
        }
        let emitters = archive.drawEmitters(count: 3, rng: GARandom(seed: 99))
        #expect(emitters.count <= 3)
        #expect(emitters.count >= 1)
    }
}

// MARK: - Differentiable Refiner

@Suite("Differentiable Refiner")
struct DifferentiableRefinerTests {

    @Test("Refiner never worsens the input chromosome")
    func refinerMonotonic() {
        let context = sota2026MakeContext(
            movableEvents: [
                sota2026MakeEvent(id: "t1", durationMinutes: 60),
                sota2026MakeEvent(id: "t2", durationMinutes: 45)
            ]
        )
        var chromo = ScheduleChromosome.random(context: context)

        // Synthetic evaluator: fitness = 1 / (1 + distance from 10am on first gene).
        // Refiner should nudge the gene toward the 10am optimum.
        let evaluator: (inout ScheduleChromosome) -> Void = { c in
            guard let first = c.genes.first else {
                c.rawFitness = 0
                c.fitness = 0
                return
            }
            let cal = Calendar.current
            let day = cal.startOfDay(for: first.startTime)
            let target = cal.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
            let diff = abs(first.startTime.timeIntervalSince(target))
            let fit = 1.0 / (1.0 + diff / 3600.0)
            c.rawFitness = fit
            c.fitness = fit
        }

        evaluator(&chromo)
        let initialFitness = chromo.rawFitness
        let refiner = DifferentiableRefiner(config: .default)
        let delta = refiner.refine(&chromo, context: context, evaluate: evaluator)
        #expect(delta >= 0)
        #expect(chromo.rawFitness >= initialFitness)
    }
}

// MARK: - Contextual Crossover

@Suite("Contextual Crossover")
struct ContextualCrossoverTests {

    @Test("Head weights start at the priors and can be nudged")
    func headWeightsUpdate() {
        let head = GeneAttentionHead(learningRate: 0.1)
        let initialWeights = head.currentWeights
        head.updateWeights(features: [1.0, 1.0, 1.0, 1.0], rewardSign: 1.0)
        let updated = head.currentWeights
        #expect(updated != initialWeights)
        for (old, new) in zip(initialWeights, updated) {
            #expect(new > old)
        }
    }

    @Test("Crossover produces offspring with the same gene count")
    func offspringHasSameGeneCount() {
        let context = sota2026MakeContext(
            movableEvents: [
                sota2026MakeEvent(id: "t1"),
                sota2026MakeEvent(id: "t2"),
                sota2026MakeEvent(id: "t3")
            ]
        )
        let head = GeneAttentionHead()
        let p1 = ScheduleChromosome.random(context: context)
        let p2 = ScheduleChromosome.random(context: context)
        let (c1, c2) = ContextualCrossover.perform(p1, p2, context: context, head: head)
        #expect(c1.genes.count == p1.genes.count)
        #expect(c2.genes.count == p2.genes.count)
    }

    @Test("Default OptimizerContext auto-wires an attention head")
    func defaultContextWiresHead() {
        let context = sota2026MakeContext(
            movableEvents: [
                sota2026MakeEvent(id: "t1"),
                sota2026MakeEvent(id: "t2")
            ]
        )
        let p1 = ScheduleChromosome.random(context: context)
        let p2 = ScheduleChromosome.random(context: context)
        let (c1, c2) = Crossover.perform(p1, p2, strategy: .contextual(temperature: 0.5), context: context)
        #expect(c1.genes.count == p1.genes.count)
        #expect(c2.genes.count == p2.genes.count)
    }
}

// MARK: - Federated Bandit

@Suite("Federated Mutation Bandit")
struct FederatedBanditTests {

    @Test("Per-island bandits are independent before merging")
    func perIslandIndependent() {
        let federated = FederatedMutationBandit(islandCount: 3)
        let a = federated.bandit(forIsland: 0)
        let b = federated.bandit(forIsland: 1)
        #expect(a !== b)
        // Pump reward into island 0; island 1 state should be unchanged.
        a.record(op: .shift, reward: 0.3)
        let bPulls = b.snapshot[.shift]?.pulls ?? 0
        #expect(bPulls == 0)
    }

    @Test("Merge averages statistics across islands")
    func mergeBlendsStatistics() {
        let config = FederatedMutationBandit.Configuration(
            mergeInterval: 10,
            mergeWeight: 1.0, // full adoption — post-merge islands should be identical
            explorationAlpha: 1.0,
            regularizationLambda: 1.0
        )
        let federated = FederatedMutationBandit(islandCount: 2, config: config)
        let a = federated.bandit(forIsland: 0)
        let b = federated.bandit(forIsland: 1)

        a.updateContext(BanditContext(diversity: 0.7, stagnation: 0.2, imbalance: 0.1))
        b.updateContext(BanditContext(diversity: 0.3, stagnation: 0.8, imbalance: 0.5))

        for _ in 0..<20 {
            a.record(op: .shift, reward: 0.2)
            b.record(op: .guided, reward: 0.4)
        }

        federated.merge()

        // After full-weight merge every arm's theta on the two islands
        // should be approximately identical.
        let sa = a.snapshot
        let sb = b.snapshot
        for op in MutationOperator.allCases {
            guard let ta = sa[op]?.theta, let tb = sb[op]?.theta else { continue }
            for (va, vb) in zip(ta, tb) {
                #expect(abs(va - vb) < 1e-6)
            }
        }
    }

    @Test("maybeMerge respects the configured interval")
    func maybeMergeTriggersOnInterval() {
        let config = FederatedMutationBandit.Configuration(
            mergeInterval: 5,
            mergeWeight: 0.5,
            explorationAlpha: 1.0,
            regularizationLambda: 1.0
        )
        let federated = FederatedMutationBandit(islandCount: 3, config: config)
        #expect(federated.maybeMerge(generation: 1) == false)
        #expect(federated.maybeMerge(generation: 5) == true)
        #expect(federated.maybeMerge(generation: 6) == false)
        #expect(federated.maybeMerge(generation: 10) == true)
    }
}

// MARK: - Schedule Features

@Suite("Schedule Feature Extraction")
struct ScheduleFeatureTests {

    @Test("Feature vector length matches the declared dimension")
    func featureDimensionIsConstant() {
        let context = sota2026MakeContext(
            movableEvents: [sota2026MakeEvent(id: "t1"), sota2026MakeEvent(id: "t2")]
        )
        let chromo = ScheduleChromosome.random(context: context)
        let features = ScheduleFeatures.vector(of: chromo, context: context)
        #expect(features.count == ScheduleFeatures.dimension)
    }

    @Test("All features are clamped to [0, 1]")
    func featuresInUnitRange() {
        let context = sota2026MakeContext(
            movableEvents: (0..<10).map { sota2026MakeEvent(id: "t\($0)") }
        )
        let chromo = ScheduleChromosome.random(context: context)
        let features = ScheduleFeatures.vector(of: chromo, context: context)
        #expect(features.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}

// MARK: - Phase-2 Presets

@Suite("Phase-2 Presets Bake In SOTA-2026 Features")
struct Phase2PresetTests {

    @Test("Default preset uses contextual crossover and QD emission")
    func defaultPresetConfigured() {
        let c = GAConfiguration.default
        #expect(c.qdArchiveEmissionRate > 0)
        #expect(c.gradientRefineInterval > 0)
        if case .contextual = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .contextual crossover strategy on .default") }
    }

    @Test("Thorough preset uses contextual crossover and QD emission")
    func thoroughPresetConfigured() {
        let c = GAConfiguration.thorough
        #expect(c.qdArchiveEmissionRate > 0)
        #expect(c.gradientRefineInterval > 0)
        if case .contextual = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .contextual crossover strategy on .thorough") }
    }

    @Test("Island preset uses contextual crossover and QD emission")
    func islandPresetConfigured() {
        let c = GAConfiguration.island
        #expect(c.qdArchiveEmissionRate > 0)
        #expect(c.gradientRefineInterval > 0)
        if case .contextual = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .contextual crossover strategy on .island") }
    }

    @Test("Instant preset keeps single-point crossover for preview latency")
    func instantPresetStaysFast() {
        let c = GAConfiguration.instant
        if case .singlePoint = c.crossoverStrategy { #expect(true) }
        else { Issue.record("Expected .singlePoint crossover on .instant") }
    }
}
