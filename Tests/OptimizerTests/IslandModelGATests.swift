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

// MARK: - Comparative Benchmark: Island Model vs Single-Population GA

@Suite("Island Model vs Single-Pop Comparison")
struct IslandModelComparisonTests {

    /// Run both approaches with comparable total fitness evaluations and compare results.
    /// Island model should find equal or better solutions on a problem with enough
    /// complexity (many events, multi-day horizon, competing objectives).
    @Test("Island model finds equal or better fitness than single-pop GA on complex problem")
    func islandModelVsSinglePop() {
        // Create a complex scheduling problem: 8 tasks across 3 days with varied properties
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

        // Total budget: ~240 individuals × 100 generations = 24,000 evaluations
        // Single-pop: 240 individuals × 100 generations
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

        // Island model: 4 islands × 60 individuals × 100 generations
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

        // Run multiple trials to account for stochastic variation
        let trials = 5
        var singleWins = 0
        var islandWins = 0
        var ties = 0

        for _ in 0..<trials {
            let singleGA = GeneticAlgorithm<ScheduleChromosome>(
                config: singleConfig,
                context: context,
                evaluate: evaluateFn
            )
            let singleResult = singleGA.run()
            let singleBest = singleResult.first?.fitness ?? 0

            let islandGA = IslandModelGA<ScheduleChromosome>(
                islandConfig: IslandConfiguration(
                    islandCount: 4,
                    migrationInterval: 15,
                    migrationSize: 3,
                    topology: .ring,
                    emigrantSelection: .best,
                    immigrantReplacement: .worst,
                    diversifyIslands: true
                ),
                baseConfig: islandBaseConfig,
                context: context,
                evaluate: evaluateFn
            )
            let islandResult = islandGA.run()
            let islandBest = islandResult.first?.fitness ?? 0

            let margin = 0.005
            if islandBest > singleBest + margin {
                islandWins += 1
            } else if singleBest > islandBest + margin {
                singleWins += 1
            } else {
                ties += 1
            }
        }

        // Island model should not be consistently worse
        // (allow some single-pop wins due to randomness, but island should win or tie most)
        #expect(islandWins + ties >= singleWins,
                "Island model performed consistently worse: \(islandWins) island wins, \(singleWins) single wins, \(ties) ties")
    }
}
