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
    energyCost: Double = 0.5,
    deadline: Date? = nil,
    isFocusBlock: Bool = false
) -> OptimizableEvent {
    OptimizableEvent(
        id: id,
        title: title,
        duration: TimeInterval(durationMinutes * 60),
        deadline: deadline,
        priority: priority,
        context: context,
        energyCost: energyCost,
        isFocusBlock: isFocusBlock
    )
}

private func makeFixedEvent(
    id: String = "fixed1",
    title: String = "Fixed Meeting",
    startHour: Int,
    durationMinutes: Int = 60
) -> CalendarEvent {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let start = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: today)!
    let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))

    return CalendarEvent(
        id: id,
        title: title,
        startDate: start,
        endDate: end,
        location: nil,
        description: nil,
        calendarName: "Test",
        eventType: .standard
    )
}

// MARK: - Chromosome Tests

@Suite("Chromosome Tests")
struct ChromosomeTests {

    @Test("Random chromosome creates genes for all movable events")
    func randomChromosomeCreatesAllGenes() {
        let events = [
            makeMovableEvent(id: "t1", title: "Task 1"),
            makeMovableEvent(id: "t2", title: "Task 2"),
            makeMovableEvent(id: "t3", title: "Task 3"),
        ]
        let context = makeContext(movableEvents: events)

        let chromosome = ScheduleChromosome.random(context: context)
        #expect(chromosome.genes.count == 3)

        let ids = Set(chromosome.genes.map(\.eventId))
        #expect(ids == Set(["t1", "t2", "t3"]))
    }

    @Test("Crossover produces two children with all genes")
    func crossoverProducesValidChildren() {
        let events = [
            makeMovableEvent(id: "t1"),
            makeMovableEvent(id: "t2"),
            makeMovableEvent(id: "t3"),
        ]
        let context = makeContext(movableEvents: events)

        let parent1 = ScheduleChromosome.random(context: context)
        let parent2 = ScheduleChromosome.random(context: context)

        let (child1, child2) = parent1.crossover(with: parent2, context: context)

        #expect(child1.genes.count == 3)
        #expect(child2.genes.count == 3)
    }

    @Test("Mutation changes at least one gene with high rate")
    func mutationChangesGenes() {
        let events = [makeMovableEvent(id: "t1", durationMinutes: 60)]
        let context = makeContext(movableEvents: events)

        var chromosome = ScheduleChromosome.random(context: context)
        let originalStart = chromosome.genes[0].startTime

        // With 100% mutation rate, the gene should change
        var changed = false
        for _ in 0..<10 {
            var copy = chromosome
            copy.mutate(rate: 1.0, context: context)
            if copy.genes[0].startTime != originalStart {
                changed = true
                break
            }
        }
        #expect(changed)
    }
}

// MARK: - Population Tests

@Suite("Population Tests")
struct PopulationTests {

    @Test("Population initializes with correct size")
    func populationSize() {
        let context = makeContext(movableEvents: [makeMovableEvent()])
        let pop = Population<ScheduleChromosome>(size: 20, eliteCount: 2, context: context)
        #expect(pop.size == 20)
        #expect(pop.eliteCount == 2)
    }

    @Test("Elites are the top N by fitness")
    func elitesAreTopN() {
        let context = makeContext(movableEvents: [makeMovableEvent()])
        var pop = Population<ScheduleChromosome>(size: 10, eliteCount: 2, context: context)

        // Assign increasing fitness
        for i in pop.individuals.indices {
            pop.individuals[i].fitness = Double(i)
        }

        let elites = pop.elites
        #expect(elites.count == 2)
        #expect(elites[0].fitness == 9.0)
        #expect(elites[1].fitness == 8.0)
    }
}

// MARK: - Constraint Tests

@Suite("Constraint Tests")
struct ConstraintTests {

    @Test("NoOverlapConstraint detects overlapping events")
    func noOverlapDetectsOverlap() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!

        let gene1 = ScheduleGene(eventId: "a", title: "Event A", startTime: start, duration: 3600, context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)
        let gene2 = ScheduleGene(eventId: "b", title: "Event B", startTime: start.addingTimeInterval(1800), duration: 3600, context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)

        let chromosome = ScheduleChromosome(genes: [gene1, gene2])
        let context = makeContext()

        let constraint = NoOverlapConstraint()
        let penalty = constraint.penalty(for: chromosome, context: context)
        #expect(penalty > 0)
    }

    @Test("NoOverlapConstraint returns zero for non-overlapping events")
    func noOverlapPassesClean() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start1 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let start2 = cal.date(bySettingHour: 12, minute: 0, second: 0, of: today)!

        let gene1 = ScheduleGene(eventId: "a", title: "Event A", startTime: start1, duration: 3600, context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)
        let gene2 = ScheduleGene(eventId: "b", title: "Event B", startTime: start2, duration: 3600, context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)

        let chromosome = ScheduleChromosome(genes: [gene1, gene2])
        let context = makeContext()

        let constraint = NoOverlapConstraint()
        let penalty = constraint.penalty(for: chromosome, context: context)
        #expect(penalty == 0)
    }

    @Test("WorkingHoursConstraint penalizes events outside hours")
    func workingHoursConstraint() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: 7, minute: 0, second: 0, of: today)!  // before 9 AM

        let gene = ScheduleGene(eventId: "a", title: "Event A", startTime: start, duration: 3600, context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)
        let chromosome = ScheduleChromosome(genes: [gene])
        let context = makeContext(workingHours: 9...18)

        let constraint = WorkingHoursConstraint()
        let penalty = constraint.penalty(for: chromosome, context: context)
        #expect(penalty > 0)
    }
}

// MARK: - Objective Tests

@Suite("Objective Tests")
struct ObjectiveTests {

    @Test("ConflictObjective returns 1.0 for no conflicts")
    func noConflictsScoresHigh() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let gene = ScheduleGene(
            eventId: "a",
            title: "Event A",
            startTime: cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!,
            duration: 3600,
            context: nil,
            energyCost: 0.5,
            priority: 0.5,
            isFocusBlock: false
        )

        let chromosome = ScheduleChromosome(genes: [gene])
        let context = makeContext()

        let objective = ConflictObjective()
        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score == 1.0)
    }

    @Test("ContextSwitchObjective rewards same-context clustering")
    func contextSwitchRewardsClusters() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let genes = (0..<3).map { i in
            ScheduleGene(
                eventId: "t\(i)",
                title: "Task \(i)",
                startTime: cal.date(bySettingHour: 10 + i, minute: 0, second: 0, of: today)!,
                duration: 3600,
                context: "projectA",
                energyCost: 0.5,
                priority: 0.5,
                isFocusBlock: false
            )
        }

        let sameContext = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let objective = ContextSwitchObjective()
        let score = objective.evaluate(chromosome: sameContext, context: context)
        #expect(score > 0.8)  // Same context = good
    }

    @Test("BufferObjective rewards adequate gaps")
    func bufferRewardsGaps() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Two events with 30-minute gap
        let gene1 = ScheduleGene(eventId: "a", title: "Event A", startTime: cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!, duration: 3600, context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)
        let gene2 = ScheduleGene(eventId: "b", title: "Event B", startTime: cal.date(bySettingHour: 11, minute: 30, second: 0, of: today)!, duration: 3600, context: nil, energyCost: 0.5, priority: 0.5, isFocusBlock: false)

        let chromosome = ScheduleChromosome(genes: [gene1, gene2])
        let context = makeContext()

        let objective = BufferObjective()
        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score == 1.0)  // 30 min gap > 5 min default buffer
    }
}

// MARK: - Fitness Evaluator Tests

@Suite("Fitness Evaluator Tests")
struct FitnessEvaluatorTests {

    @Test("FitnessEvaluator combines objectives and constraints")
    func evaluatorCombines() {
        let preferences = OptimizerPreferences()
        let evaluator = FitnessEvaluator.standard(preferences: preferences)
        let context = makeContext(movableEvents: [makeMovableEvent()])

        var chromosome = ScheduleChromosome.random(context: context)
        evaluator.evaluateAndAssign(&chromosome, context: context)

        // Fitness should be a finite number
        #expect(chromosome.fitness.isFinite)
    }

    @Test("Objective breakdown returns all 11 objectives")
    func objectiveBreakdownComplete() {
        let preferences = OptimizerPreferences()
        let evaluator = FitnessEvaluator.standard(preferences: preferences)
        let context = makeContext(movableEvents: [makeMovableEvent()])
        let chromosome = ScheduleChromosome.random(context: context)

        let breakdown = evaluator.objectiveBreakdown(for: chromosome, context: context)
        #expect(breakdown.count == 11)
    }
}

// MARK: - GA Integration Tests

@Suite("GA Integration Tests")
struct GAIntegrationTests {

    @Test("GA converges to a solution")
    func gaConverges() {
        let events = [
            makeMovableEvent(id: "t1", title: "Task 1", durationMinutes: 60),
            makeMovableEvent(id: "t2", title: "Task 2", durationMinutes: 30),
        ]
        let fixed = [
            makeFixedEvent(id: "f1", title: "Standup", startHour: 10, durationMinutes: 30),
        ]
        let context = makeContext(fixedEvents: fixed, movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: context.preferences)

        let ga = GeneticAlgorithm<ScheduleChromosome>(
            config: .quick,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let results = ga.run()

        #expect(!results.isEmpty)
        #expect(results[0].fitness >= results.last!.fitness) // Sorted by fitness
        #expect(ga.bestEver != nil)
    }

    @Test("Scenario generator returns diverse results")
    func scenarioGeneratorDiverse() {
        let events = [
            makeMovableEvent(id: "t1", durationMinutes: 60),
            makeMovableEvent(id: "t2", durationMinutes: 45),
            makeMovableEvent(id: "t3", durationMinutes: 30),
        ]
        let context = makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: context.preferences)

        let ga = GeneticAlgorithm<ScheduleChromosome>(
            config: .quick,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        let population = ga.run()

        let generator = ScenarioGenerator()
        let scenarios = generator.generateScenarios(
            from: population,
            context: context,
            evaluator: evaluator
        )

        #expect(scenarios.count >= 1)
        #expect(scenarios.count <= 3)
    }
}

// MARK: - Preference Learner Tests

@Suite("Preference Learner Tests")
struct PreferenceLearnerTests {

    @Test("Preference learner starts with default weights")
    func defaultWeights() {
        let learner = PreferenceLearner()
        #expect(learner.learnedWeights["FocusBlock"] == 1.0)
        #expect(learner.learnedWeights["Conflict"] == 10.0)
    }

    @Test("Recording feedback increases history count")
    func feedbackRecorded() {
        let learner = PreferenceLearner()
        learner.recordAcceptance(scenarioFitness: 0.8)
        learner.recordRejection(scenarioFitness: 0.3)
        #expect(learner.feedbackHistory.count == 2)
    }
}

// MARK: - Event Conversion Tests

@Suite("Event Conversion Tests")
struct EventConversionTests {

    @Test("CalendarEvent converts to OptimizableEvent")
    func calendarToOptimizable() {
        let event = CalendarEvent(
            id: "test1",
            title: "Test Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            location: nil,
            description: nil,
            calendarName: "Work",
            eventType: .standard
        )

        let optimizable = event.toOptimizableEvent(priority: 0.8, context: "project-x")
        #expect(optimizable.id == "test1")
        #expect(optimizable.title == "Test Meeting")
        #expect(optimizable.duration == 3600)
        #expect(optimizable.priority == 0.8)
        #expect(optimizable.context == "project-x")
    }

    @Test("ScheduleGene converts to CalendarEvent")
    func geneToCalendarEvent() {
        let start = Date()
        let gene = ScheduleGene(
            eventId: "g1",
            title: "Focus Block",
            startTime: start,
            duration: 3600,
            context: nil,
            energyCost: 0.5,
            priority: 0.5,
            isFocusBlock: true
        )

        let event = gene.toCalendarEvent(title: "Focus Block", colorTag: .blue)
        #expect(event.id == "g1")
        #expect(event.title == "Focus Block")
        #expect(event.colorTag == .blue)
        #expect(event.startDate == start)
    }
}
