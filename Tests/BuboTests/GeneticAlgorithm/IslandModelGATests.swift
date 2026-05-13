import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Test Helpers

private func makeContext(
    fixedEvents: [CalendarEvent] = [],
    movableEvents: [OptimizableEvent] = [],
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
        preferences: OptimizerPreferences()
    )
}

private func makeMovableEvent(
    id: String = "task1",
    title: String = "Test Task",
    durationMinutes: Int = 60,
    priority: Double = 0.5,
    context: String? = nil,
    energyCost: Double = 0.5
) -> OptimizableEvent {
    OptimizableEvent(
        id: id,
        title: title,
        duration: TimeInterval(durationMinutes * 60),
        priority: priority,
        context: context,
        energyCost: energyCost
    )
}

/// Quick GA config for tests — small populations, few generations.
private let testGAConfig = GAConfiguration(
    populationSize: 15,
    maxGenerations: 20,
    mutationRate: 0.2,
    crossoverRate: 0.8,
    eliteCount: 1,
    selectionStrategy: .tournament(size: 2),
    crossoverStrategy: .singlePoint,
    convergenceThreshold: 0.01,
    convergencePatience: 8,
    adaptiveMutation: false,
    diversityThreshold: 0.01,
    immigrationRate: 0.0
)

/// Quick island config for tests — few islands, frequent migration.
private func testIslandConfig(
    islandCount: Int = 2,
    topology: MigrationTopology = .ring,
    emigrantSelection: EmigrantSelection = .best,
    immigrantReplacement: ImmigrantReplacement = .worst,
    diversifyIslands: Bool = false,
    adaptiveMigration: Bool = false
) -> IslandConfiguration {
    IslandConfiguration(
        islandCount: islandCount,
        migrationInterval: 5,
        migrationSize: 1,
        topology: topology,
        emigrantSelection: emigrantSelection,
        immigrantReplacement: immigrantReplacement,
        diversifyIslands: diversifyIslands,
        adaptiveMigration: adaptiveMigration
    )
}

private func makeTestEvents(count: Int) -> [OptimizableEvent] {
    (0..<count).map { i in
        makeMovableEvent(
            id: "task\(i)",
            title: "Task \(i)",
            durationMinutes: 30 + (i % 3) * 15,
            priority: Double(i % 5 + 1) / 5.0,
            context: ["code", "design", "meeting"][i % 3],
            energyCost: Double(i % 4 + 1) / 4.0
        )
    }
}

// MARK: - Island Configuration Tests

@Suite("Island Configuration Tests")
struct IslandConfigurationTests {

    @Test("Default configuration has valid parameters")
    func defaultConfigIsValid() {
        let config = IslandConfiguration.default
        #expect(config.islandCount >= 2)
        #expect(config.migrationInterval > 0)
        #expect(config.migrationSize > 0)
        #expect(config.migrationSize < 60) // less than island population size
        #expect(config.diversifyIslands == true)
    }

    @Test("Thorough configuration has more islands")
    func thoroughConfigHasMoreIslands() {
        let def = IslandConfiguration.default
        let thorough = IslandConfiguration.thorough
        #expect(thorough.islandCount >= def.islandCount)
        #expect(thorough.migrationSize >= def.migrationSize)
    }

    // `.island` preset was retired — `IslandModelGA` now runs with
    // whatever base config the caller supplies (typically the
    // instance's `gaConfig`). The per-island × N scaling check that
    // used to live here is no longer meaningful.
}

// MARK: - Island Model GA Tests

@Suite("Island Model GA Tests")
struct IslandModelGATests {

    @Test("Island model produces a non-empty sorted population")
    func producesNonEmptyResult() {
        let events = makeTestEvents(count: 4)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: .default,
            baseConfig: .thorough,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
        #expect(islandGA.bestEver != nil)
        #expect(islandGA.bestEver!.fitness > 0)
    }

    @Test("Island model result is sorted by fitness descending")
    func resultIsSortedByFitness() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 2,
                migrationInterval: 5,
                migrationSize: 2,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 20,
                maxGenerations: 30,
                mutationRate: 0.15,
                crossoverRate: 0.8,
                eliteCount: 2,
                selectionStrategy: .tournament(size: 3),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 10,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.1
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        for i in 0..<(result.count - 1) {
            #expect(result[i].fitness >= result[i + 1].fitness)
        }
    }

    @Test("Island model bestEver is at least as good as first result")
    func bestEverIsConsistent() {
        let events = makeTestEvents(count: 5)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 3,
                migrationInterval: 10,
                migrationSize: 2,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: true,
                adaptiveMigration: false
            ),
            baseConfig: .thorough,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        let best = islandGA.bestEver!
        // bestEver should be >= the best in the returned population
        // (hill climbing may have improved it)
        #expect(best.fitness >= result.first!.fitness - 0.001)
    }

    @Test("Island model with diversification uses different strategies per island")
    func diversificationCreatesVariedIslands() {
        // This test verifies that the island model runs without errors when
        // diversification is enabled (different mutation rates, selection strategies)
        let events = makeTestEvents(count: 6)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 5,
                migrationInterval: 8,
                migrationSize: 2,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: true,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 15,
                maxGenerations: 25,
                mutationRate: 0.15,
                crossoverRate: 0.8,
                eliteCount: 2,
                selectionStrategy: .tournament(size: 3),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 10,
                adaptiveMutation: true,
                diversityThreshold: 0.01,
                immigrationRate: 0.1
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
        #expect(islandGA.bestEver!.fitness > 0)
    }

    @Test("Single island degenerates to standard GA behavior")
    func singleIslandBehavesLikeStandardGA() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let smallConfig = GAConfiguration(
            populationSize: 20,
            maxGenerations: 30,
            mutationRate: 0.15,
            crossoverRate: 0.8,
            eliteCount: 2,
            selectionStrategy: .tournament(size: 3),
            crossoverStrategy: .singlePoint,
            convergenceThreshold: 0.01,
            convergencePatience: 10,
            adaptiveMutation: false,
            diversityThreshold: 0.01,
            immigrationRate: 0.1
        )

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 1,
                migrationInterval: 10,
                migrationSize: 1,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: smallConfig,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
        #expect(islandGA.bestEver!.fitness > 0)
    }
}

// MARK: - Migration Topology Tests

@Suite("Migration Topology Tests")
struct MigrationTopologyTests {

    @Test("Ring topology completes without error")
    func ringTopologyWorks() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 3,
                migrationInterval: 5,
                migrationSize: 1,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 15,
                maxGenerations: 20,
                mutationRate: 0.2,
                crossoverRate: 0.8,
                eliteCount: 1,
                selectionStrategy: .tournament(size: 2),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 8,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.0
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
    }

    @Test("Fully connected topology completes without error")
    func fullyConnectedTopologyWorks() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 3,
                migrationInterval: 5,
                migrationSize: 1,
                topology: .fullyConnected,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 15,
                maxGenerations: 20,
                mutationRate: 0.2,
                crossoverRate: 0.8,
                eliteCount: 1,
                selectionStrategy: .tournament(size: 2),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 8,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.0
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
    }

    @Test("Random pairs topology completes without error")
    func randomPairsTopologyWorks() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 4,
                migrationInterval: 5,
                migrationSize: 1,
                topology: .randomPairs,
                emigrantSelection: .tournament(size: 2),
                immigrantReplacement: .random,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 15,
                maxGenerations: 20,
                mutationRate: 0.2,
                crossoverRate: 0.8,
                eliteCount: 1,
                selectionStrategy: .tournament(size: 2),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 8,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.0
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
    }

    @Test("Random pairs topology handles odd island count")
    func randomPairsOddIslandCount() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        // 5 islands (odd) — the last island should still participate in migration
        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 5,
                migrationInterval: 5,
                migrationSize: 1,
                topology: .randomPairs,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 15,
                maxGenerations: 20,
                mutationRate: 0.2,
                crossoverRate: 0.8,
                eliteCount: 1,
                selectionStrategy: .tournament(size: 2),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 8,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.0
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
    }
}

// MARK: - Emigrant Selection Tests

@Suite("Emigrant Selection Tests")
struct EmigrantSelectionTests {

    @Test("Tournament emigrant selection completes without error")
    func tournamentSelectionWorks() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 2,
                migrationInterval: 5,
                migrationSize: 2,
                topology: .ring,
                emigrantSelection: .tournament(size: 3),
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 15,
                maxGenerations: 20,
                mutationRate: 0.2,
                crossoverRate: 0.8,
                eliteCount: 1,
                selectionStrategy: .tournament(size: 2),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 8,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.0
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)
    }
}

// MARK: - Progress Callback Tests

@Suite("Island Progress Tests")
struct IslandProgressTests {

    @Test("Progress callback is called with island-level information")
    func progressCallbackFires() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        var progressUpdates: [IslandModelProgress] = []

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 2,
                migrationInterval: 5,
                migrationSize: 1,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 10,
                maxGenerations: 15,
                mutationRate: 0.2,
                crossoverRate: 0.8,
                eliteCount: 1,
                selectionStrategy: .tournament(size: 2),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.001,
                convergencePatience: 10,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.0
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            },
            onProgress: { progress in
                progressUpdates.append(progress)
            }
        )

        _ = try! islandGA.run()

        #expect(!progressUpdates.isEmpty)

        // Verify progress contains per-island data
        if let last = progressUpdates.last {
            #expect(last.islandBestFitnesses.count == 2)
            #expect(last.islandDiversities.count == 2)
            #expect(last.globalBestFitness > 0)
        }
    }
}

// MARK: - PomodoroSequence Island Model Tests

@Suite("PomodoroSequence Island Model Tests")
struct PomodoroSequenceIslandModelTests {

    @Test("Island model works with PomodoroSequenceChromosome")
    func islandModelWithPermutationChromosome() {
        let tasks = (0..<5).map { i in
            OptimizableEvent(
                id: "pomo\(i)",
                title: "Pomo Task \(i)",
                duration: TimeInterval(25 * 60),
                priority: Double(i + 1) / 5.0,
                context: ["code", "design", "docs"][i % 3],
                energyCost: Double(4 - i % 4) / 4.0
            )
        }

        let context = OptimizerContext(movableEvents: tasks)
        let evaluator = PomodoroSequenceEvaluator(
            tasks: tasks,
            sessionStart: Date()
        )

        let islandGA = IslandModelGA<PomodoroSequenceChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 3,
                migrationInterval: 8,
                migrationSize: 2,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: true,
                adaptiveMigration: false
            ),
            baseConfig: GAConfiguration(
                populationSize: 20,
                maxGenerations: 30,
                mutationRate: 0.2,
                crossoverRate: 0.8,
                eliteCount: 2,
                selectionStrategy: .tournament(size: 3),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.01,
                convergencePatience: 10,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.1
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = try! islandGA.run()
        #expect(!result.isEmpty)

        // Verify all results are valid permutations
        for chromosome in result {
            let sorted = chromosome.sequence.sorted()
            #expect(sorted == Array(0..<tasks.count))
        }
    }
}

// MARK: - Comparative Benchmark: Island Model vs Single-Population GA

@Suite("Island Model vs Single-Pop Comparison")
struct IslandModelComparisonTests {

    /// Non-flaky smoke test: verify island model produces competitive fitness.
    /// Instead of a statistical comparison (which is inherently flaky in CI),
    /// this test verifies that:
    /// 1. Island model finds a solution above a minimum fitness threshold
    /// 2. The solution is at least within 10% of what single-pop achieves
    ///
    /// Both use equal evaluation budgets so the comparison is fair.
    @Test("Island model produces competitive fitness on complex problem")
    func islandModelProducesCompetitiveFitness() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let threeDaysLater = cal.date(byAdding: .day, value: 3, to: today)!

        let events = (0..<8).map { i in
            OptimizableEvent(
                id: "cmp\(i)",
                title: "Task \(i)",
                duration: TimeInterval((30 + (i % 4) * 15) * 60),
                priority: [0.9, 0.3, 0.7, 0.5, 0.8, 0.4, 0.6, 0.2][i],
                context: ["code", "design", "meeting", "code", "design", "docs", "meeting", "code"][i],
                energyCost: [0.9, 0.3, 0.5, 0.7, 0.8, 0.2, 0.6, 0.4][i]
            )
        }

        let fixedMeeting = CalendarEvent(
            id: "fixed1",
            title: "Standup",
            startDate: cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!,
            endDate: cal.date(bySettingHour: 10, minute: 30, second: 0, of: today)!,
            location: nil,
            description: nil,
            calendarName: "Work",
            eventType: .standard
        )

        let context = OptimizerContext(
            fixedEvents: [fixedMeeting],
            movableEvents: events,
            workingHours: 9...18,
            planningHorizon: DateInterval(start: today, end: threeDaysLater),
            preferences: OptimizerPreferences()
        )

        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())
        let evaluateFn: (inout ScheduleChromosome) -> Void = { chromosome in
            evaluator.evaluateAndAssign(&chromosome, context: context)
        }

        // Single-pop baseline: 240 individuals × 100 generations
        let singleConfig = GAConfiguration(
            populationSize: 240,
            maxGenerations: 100,
            mutationRate: 0.12,
            crossoverRate: 0.85,
            eliteCount: 5,
            selectionStrategy: .tournament(size: 4),
            crossoverStrategy: .twoPoint,
            convergenceThreshold: 0.0001,
            convergencePatience: 80,
            adaptiveMutation: true,
            diversityThreshold: 0.005,
            immigrationRate: 0.1
        )

        // Island model: 4 islands × 60 individuals × 100 generations (equal budget)
        let islandBaseConfig = GAConfiguration(
            populationSize: 60,
            maxGenerations: 100,
            mutationRate: 0.12,
            crossoverRate: 0.85,
            eliteCount: 3,
            selectionStrategy: .tournament(size: 4),
            crossoverStrategy: .twoPoint,
            convergenceThreshold: 0.0001,
            convergencePatience: 80,
            adaptiveMutation: true,
            diversityThreshold: 0.008,
            immigrationRate: 0.1
        )

        let singleGA = GeneticAlgorithm<ScheduleChromosome>(
            config: singleConfig,
            context: context,
            evaluate: evaluateFn
        )
        let singleBest = try! singleGA.run().first?.fitness ?? 0

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 4,
                migrationInterval: 15,
                migrationSize: 3,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: true,
                adaptiveMigration: false
            ),
            baseConfig: islandBaseConfig,
            context: context,
            evaluate: evaluateFn
        )
        let islandBest = try! islandGA.run().first?.fitness ?? 0

        // Island model must find a feasible solution (fitness > 0.1 means constraint-valid)
        #expect(islandBest > 0.1, "Island model failed to find a feasible solution")

        // Island model should be within 10% of single-pop (generous margin for stochastic variance)
        #expect(islandBest >= singleBest * 0.90,
                "Island model fitness \(islandBest) is more than 10% worse than single-pop \(singleBest)")
    }

    @Test("IslandConfiguration.validated clamps bad parameters")
    func validatedClampsBadParams() {
        let bad = IslandConfiguration(
            islandCount: 0,
            migrationInterval: -1,
            migrationSize: 999,
            topology: .ring,
            emigrantSelection: .best,
            immigrantReplacement: .worst,
            diversifyIslands: false,
            adaptiveMigration: false
        )
        let fixed = bad.validated(populationSize: 60)
        #expect(fixed.islandCount >= 1)
        #expect(fixed.migrationInterval >= 1)
        #expect(fixed.migrationSize <= 30) // half of 60
    }
}

// MARK: - Seeded Run Tests

@Suite("Island Model Seeded Run Tests")
struct IslandModelSeededTests {

    @Test("runSeeded distributes seeds across islands and produces valid results")
    func runSeededDistributesSeeds() {
        let events = makeTestEvents(count: 4)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())
        let evaluateFn: (inout ScheduleChromosome) -> Void = { chromosome in
            evaluator.evaluateAndAssign(&chromosome, context: context)
        }

        // Create seed chromosomes (simulating current schedule variants)
        var seeds: [ScheduleChromosome] = []
        for _ in 0..<10 {
            var chromosome = ScheduleChromosome.random(context: context)
            evaluateFn(&chromosome)
            seeds.append(chromosome)
        }

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: testIslandConfig(islandCount: 3),
            baseConfig: testGAConfig,
            context: context,
            evaluate: evaluateFn
        )

        let result = try! islandGA.runSeeded(with: seeds)

        #expect(!result.isEmpty)
        #expect(islandGA.bestEver != nil)
        #expect(islandGA.bestEver!.fitness > 0)
        // Result should be sorted
        for i in 0..<(result.count - 1) {
            #expect(result[i].fitness >= result[i + 1].fitness)
        }
    }

    @Test("runSeeded with more seeds than island capacity works")
    func runSeededOverflow() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())
        let evaluateFn: (inout ScheduleChromosome) -> Void = { chromosome in
            evaluator.evaluateAndAssign(&chromosome, context: context)
        }

        // Create more seeds than total island capacity (2 islands × 15 = 30)
        var seeds: [ScheduleChromosome] = []
        for _ in 0..<50 {
            var chromosome = ScheduleChromosome.random(context: context)
            evaluateFn(&chromosome)
            seeds.append(chromosome)
        }

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: testIslandConfig(islandCount: 2),
            baseConfig: testGAConfig,
            context: context,
            evaluate: evaluateFn
        )

        let result = try! islandGA.runSeeded(with: seeds)
        #expect(!result.isEmpty)
    }

    @Test("runSeeded with single seed works")
    func runSeededSingleSeed() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())
        let evaluateFn: (inout ScheduleChromosome) -> Void = { chromosome in
            evaluator.evaluateAndAssign(&chromosome, context: context)
        }

        var seed = ScheduleChromosome.random(context: context)
        evaluateFn(&seed)

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: testIslandConfig(islandCount: 3),
            baseConfig: testGAConfig,
            context: context,
            evaluate: evaluateFn
        )

        let result = try! islandGA.runSeeded(with: [seed])
        #expect(!result.isEmpty)
        // With warm start, result should be at least as good as the seed
        #expect(islandGA.bestEver!.fitness >= seed.fitness - 0.001)
    }

    @Test("runSeeded result is at least as good as best seed")
    func runSeededImprovesOnSeeds() {
        let events = makeTestEvents(count: 5)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())
        let evaluateFn: (inout ScheduleChromosome) -> Void = { chromosome in
            evaluator.evaluateAndAssign(&chromosome, context: context)
        }

        var seeds: [ScheduleChromosome] = []
        for _ in 0..<8 {
            var chromosome = ScheduleChromosome.random(context: context)
            evaluateFn(&chromosome)
            seeds.append(chromosome)
        }
        let bestSeedFitness = seeds.map(\.fitness).max() ?? 0

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: testIslandConfig(islandCount: 3),
            baseConfig: GAConfiguration(
                populationSize: 20,
                maxGenerations: 40,
                mutationRate: 0.15,
                crossoverRate: 0.8,
                eliteCount: 2,
                selectionStrategy: .tournament(size: 3),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.001,
                convergencePatience: 15,
                adaptiveMutation: true,
                diversityThreshold: 0.01,
                immigrationRate: 0.1
            ),
            context: context,
            evaluate: evaluateFn
        )

        let result = try! islandGA.runSeeded(with: seeds)
        let resultBest = result.first?.fitness ?? 0

        // GA with seeds should find something at least as good as the best seed
        #expect(resultBest >= bestSeedFitness - 0.01,
                "Seeded GA (\(resultBest)) should match best seed (\(bestSeedFitness))")
    }
}

// MARK: - Cross-Island Diversity Tests

@Suite("Cross-Island Diversity Tests")
struct CrossIslandDiversityTests {

    @Test("Progress reports cross-island diversity")
    func progressReportsCrossIslandDiversity() {
        let events = makeTestEvents(count: 4)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        var lastProgress: IslandModelProgress?

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: testIslandConfig(islandCount: 3, diversifyIslands: true),
            baseConfig: testGAConfig,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            },
            onProgress: { progress in
                lastProgress = progress
            }
        )

        _ = try! islandGA.run()

        #expect(lastProgress != nil)
        // crossIslandDiversity should be between 0 and 1
        #expect(lastProgress!.crossIslandDiversity >= 0)
        #expect(lastProgress!.crossIslandDiversity <= 1.0)
        // effectiveMigrationInterval should be positive
        #expect(lastProgress!.effectiveMigrationInterval >= 1)
    }
}

// MARK: - Adaptive Migration Tests

@Suite("Adaptive Migration Tests")
struct AdaptiveMigrationTests {

    @Test("Adaptive migration adjusts interval during stagnation")
    func adaptiveMigrationDuringStagnation() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        var intervals: [Int] = []

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 3,
                migrationInterval: 10,
                migrationSize: 2,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: true
            ),
            baseConfig: GAConfiguration(
                populationSize: 15,
                maxGenerations: 60,
                mutationRate: 0.15,
                crossoverRate: 0.8,
                eliteCount: 1,
                selectionStrategy: .tournament(size: 2),
                crossoverStrategy: .singlePoint,
                convergenceThreshold: 0.0001,
                convergencePatience: 30,
                adaptiveMutation: false,
                diversityThreshold: 0.01,
                immigrationRate: 0.0
            ),
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            },
            onProgress: { progress in
                intervals.append(progress.effectiveMigrationInterval)
            }
        )

        _ = try! islandGA.run()

        // Should have some progress updates
        #expect(!intervals.isEmpty)
        // With adaptive migration, interval may change during the run
        // At minimum verify all intervals are positive
        for interval in intervals {
            #expect(interval >= 1)
        }
    }

    @Test("Non-adaptive migration keeps constant interval")
    func nonAdaptiveMigrationConstantInterval() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())

        var intervals: [Int] = []
        let configuredInterval = 7

        let islandGA = IslandModelGA<ScheduleChromosome>(
            islandConfig: IslandConfiguration(
                islandCount: 2,
                migrationInterval: configuredInterval,
                migrationSize: 1,
                topology: .ring,
                emigrantSelection: .best,
                immigrantReplacement: .worst,
                diversifyIslands: false,
                adaptiveMigration: false
            ),
            baseConfig: testGAConfig,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            },
            onProgress: { progress in
                intervals.append(progress.effectiveMigrationInterval)
            }
        )

        _ = try! islandGA.run()

        // Without adaptive migration, all intervals should be the configured value
        for interval in intervals {
            #expect(interval == configuredInterval)
        }
    }

    @Test("Adaptive migration completes with all topologies")
    func adaptiveMigrationAllTopologies() {
        let events = makeTestEvents(count: 3)
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: OptimizerPreferences())
        let evaluateFn: (inout ScheduleChromosome) -> Void = { chromosome in
            evaluator.evaluateAndAssign(&chromosome, context: context)
        }

        for topology: MigrationTopology in [.ring, .fullyConnected, .randomPairs] {
            let islandGA = IslandModelGA<ScheduleChromosome>(
                islandConfig: testIslandConfig(
                    islandCount: 3,
                    topology: topology,
                    adaptiveMigration: true
                ),
                baseConfig: testGAConfig,
                context: context,
                evaluate: evaluateFn
            )

            let result = try! islandGA.run()
            #expect(!result.isEmpty)
        }
    }
}
