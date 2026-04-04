import Foundation

// MARK: - BuboOptimizer

/// Main facade for the Bubo schedule optimization engine.
/// Combines GA core, constraints, objectives, re-optimization,
/// scenario generation, and preference learning into a single API.
///
/// All optimization methods are async and run the GA on a background thread
/// to keep the main thread responsive.
@MainActor
@Observable
final class BuboOptimizer {

    // MARK: - Components

    let preferenceLearner = PreferenceLearner()
    private let scenarioGenerator = ScenarioGenerator()
    let reoptimizer = IncrementalReoptimizer()

    // MARK: - State

    private(set) var isOptimizing = false
    private(set) var lastResult: OptimizerResult?

    /// The current schedule genes (movable events placement).
    var currentSchedule: [ScheduleGene] = []

    // MARK: - Configuration

    var gaConfig: GAConfiguration = .default
    var preferences: OptimizerPreferences = OptimizerPreferences()

    // MARK: - Full Optimization (Async)

    /// Run a full optimization for the given context.
    /// The GA runs on a background thread; progress updates are dispatched to main.
    func optimize(context: OptimizerContext, overrideConfig: GAConfiguration? = nil) async -> OptimizerResult {
        isOptimizing = true
        defer { isOptimizing = false }

        // Apply learned preferences, merging with (not replacing) user preferences
        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let adjustedContext = OptimizerContext(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            planningHorizon: context.planningHorizon,
            preferences: prefs,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar
        )

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let config = overrideConfig ?? gaConfig
        let scenGen = scenarioGenerator

        // Run GA on background thread
        let (population, convergenceGen, duration) = await Task.detached(priority: .userInitiated) {
            let startTime = Date()

            let ga = GeneticAlgorithm<ScheduleChromosome>(
                config: config,
                context: adjustedContext,
                evaluate: { chromosome in
                    evaluator.evaluateAndAssign(&chromosome, context: adjustedContext)
                }
            )

            let pop = ga.run()
            let elapsed = Date().timeIntervalSince(startTime)
            return (pop, ga.convergenceGeneration, elapsed)
        }.value

        // Back on main thread — generate scenarios and update state
        let scenarios = scenGen.generateScenarios(
            from: population,
            context: adjustedContext,
            evaluator: evaluator
        )

        let populationCount = population.prefix(10).count
        let metadata = OptimizationMetadata(
            generations: convergenceGen,
            totalDuration: duration,
            bestFitness: population.first?.fitness ?? 0,
            averageFitness: populationCount > 0
                ? population.prefix(10).reduce(0) { $0 + $1.fitness } / Double(populationCount)
                : 0,
            convergenceGeneration: convergenceGen
        )

        let result = OptimizerResult(scenarios: scenarios, metadata: metadata)
        lastResult = result

        if let best = scenarios.first {
            currentSchedule = best.genes
        }

        return result
    }

    // MARK: - Quick Optimize (Day)

    func optimizeToday(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents.filter { $0.startDate >= todayStart && $0.startDate < todayEnd },
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: max(Date(), todayStart), end: todayEnd),
            preferences: preferences
        )

        return await optimize(context: context, overrideConfig: .quick)
    }

    // MARK: - Weekly Optimize

    func optimizeWeek(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18,
        participantAvailability: [String: [DateInterval]] = [:]
    ) async -> OptimizerResult {
        let now = Date()
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: now, end: weekEnd),
            preferences: preferences,
            participantAvailability: participantAvailability
        )

        return await optimize(context: context)
    }

    // MARK: - Incremental Re-optimization (#26)

    func reoptimize(
        trigger: ReoptimizationTrigger,
        context: OptimizerContext
    ) async -> OptimizerResult? {
        isOptimizing = true
        defer { isOptimizing = false }

        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let schedule = currentSchedule
        // Capture reoptimizer config as values for thread safety
        let stabilityWeight = reoptimizer.stabilityWeight
        let minimumImprovement = reoptimizer.minimumImprovement

        let reopt = IncrementalReoptimizer()
        reopt.stabilityWeight = stabilityWeight
        reopt.minimumImprovement = minimumImprovement

        let result = await Task.detached(priority: .userInitiated) {
            reopt.reoptimize(
                currentSchedule: schedule,
                trigger: trigger,
                context: context,
                evaluator: evaluator,
                config: .quick
            )
        }.value

        // Update internal state if re-optimization succeeded
        if let result = result, let best = result.scenarios.first {
            currentSchedule = best.genes
            lastResult = result
        }

        return result
    }

    // MARK: - User Feedback (#24)

    func acceptScenario(_ scenario: ScheduleScenario) {
        currentSchedule = scenario.genes
        preferenceLearner.recordAcceptance(scenarioFitness: scenario.fitness)
    }

    func rejectScenario(_ scenario: ScheduleScenario) {
        preferenceLearner.recordRejection(scenarioFitness: scenario.fitness)
    }

    func recordManualEdit(original: [ScheduleGene], edited: [ScheduleGene]) {
        currentSchedule = edited
        preferenceLearner.recordModification(original: original, edited: edited)
    }

    // MARK: - Scenario Comparison (#27)

    func compareLastScenarios() -> [ScenarioComparison] {
        guard let result = lastResult else { return [] }
        return scenarioGenerator.compareScenarios(result.scenarios)
    }

    // MARK: - Focus Block Suggestions (#1)

    func suggestFocusBlocks(
        count: Int = 2,
        durationMinutes: Int = 120,
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let focusEvents = (0..<count).map { i in
            OptimizableEvent(
                title: "Focus Block \(i + 1)",
                duration: TimeInterval(durationMinutes * 60),
                priority: 0.8,
                context: "focus",
                energyCost: 0.7,
                preferredHourRange: 9...12,
                isFocusBlock: true
            )
        }

        return await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: focusEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Pomodoro Optimization (#2)

    func suggestPomodoroSlot(
        config: PomodoroConfig = .classic,
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let totalMinutes = config.workMinutes * config.rounds
            + config.breakMinutes * max(0, config.rounds - 1)
            + config.longBreakMinutes

        let pomodoroEvent = OptimizableEvent(
            title: "Pomodoro Session",
            duration: TimeInterval(totalMinutes * 60),
            priority: 0.7,
            context: "focus",
            energyCost: 0.8,
            preferredHourRange: 9...14,
            isFocusBlock: true,
            pomodoroConfig: config
        )

        return await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: [pomodoroEvent],
            workingHours: workingHours
        )
    }

    // MARK: - Meeting Scheduling (#5, #16)

    func suggestMeetingSlot(
        title: String,
        durationMinutes: Int,
        participants: [String],
        fixedEvents: [CalendarEvent],
        participantAvailability: [String: [DateInterval]],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let meetingEvent = OptimizableEvent(
            title: title,
            duration: TimeInterval(durationMinutes * 60),
            priority: 0.9,
            context: "meeting",
            energyCost: 0.6,
            requiredParticipants: participants
        )

        return await optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: [meetingEvent],
            workingHours: workingHours,
            participantAvailability: participantAvailability
        )
    }

    // MARK: - Pomodoro Task Sequence Optimization

    /// Optimize the order of tasks within a Pomodoro session.
    /// Uses a dedicated permutation GA (PomodoroSequenceChromosome) that considers
    /// energy curve, context switches, deadline urgency, and cognitive load alternation.
    ///
    /// Returns tasks reordered for optimal execution within the session.
    func optimizePomodoroSequence(
        tasks: [OptimizableEvent],
        sessionStart: Date = Date(),
        weights: PomodoroSequenceEvaluator.Weights = .default
    ) async -> [OptimizableEvent] {
        guard tasks.count > 1 else { return tasks }

        let capturedTasks = tasks
        let capturedStart = sessionStart
        let capturedWeights = weights
        let capturedPrefs = preferences

        return await Task.detached(priority: .userInitiated) {
            PomodoroSequenceOptimizer.optimize(
                tasks: capturedTasks,
                sessionStart: capturedStart,
                preferences: capturedPrefs,
                config: .quick,
                weights: capturedWeights
            )
        }.value
    }

    // MARK: - Day Planning (#6)

    func planDay(
        tasks: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: tasks,
            workingHours: workingHours
        )
    }

    // MARK: - Week Balancing (#9)

    func balanceWeek(
        movableEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        await optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Reset

    func reset() {
        preferenceLearner.reset()
        currentSchedule = []
        lastResult = nil
        preferences = OptimizerPreferences()
    }
}
