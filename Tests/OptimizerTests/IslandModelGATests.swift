import Foundation
import Testing
@testable import Bubo

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

    @Test("GA island preset has smaller population than thorough")
    func islandPresetHasSmallerPopulation() {
        let island = GAConfiguration.island
        let thorough = GAConfiguration.thorough
        #expect(island.populationSize < thorough.populationSize)
        // Total individuals across islands should be comparable
        let totalIsland = island.populationSize * IslandConfiguration.default.islandCount
        #expect(totalIsland >= thorough.populationSize)
    }
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
            baseConfig: .island,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = islandGA.run()
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
                diversifyIslands: false
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

        let result = islandGA.run()
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
                diversifyIslands: true
            ),
            baseConfig: .island,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = islandGA.run()
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
                diversifyIslands: true
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

        let result = islandGA.run()
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
                diversifyIslands: false
            ),
            baseConfig: smallConfig,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let result = islandGA.run()
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
                diversifyIslands: false
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

        let result = islandGA.run()
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
                diversifyIslands: false
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

        let result = islandGA.run()
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
                diversifyIslands: false
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

        let result = islandGA.run()
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
                diversifyIslands: false
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

        let result = islandGA.run()
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
                diversifyIslands: false
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

        _ = islandGA.run()

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
                diversifyIslands: true
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

        let result = islandGA.run()
        #expect(!result.isEmpty)

        // Verify all results are valid permutations
        for chromosome in result {
            let sorted = chromosome.sequence.sorted()
            #expect(sorted == Array(0..<tasks.count))
        }
    }
}
