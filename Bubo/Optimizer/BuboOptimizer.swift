import Foundation

// MARK: - BuboOptimizer

/// Main facade for the Bubo schedule optimization engine.
/// Combines GA core, constraints, objectives, re-optimization,
/// scenario generation, and preference learning into a single API.
@Observable
final class BuboOptimizer {

    // MARK: - Components

    let preferenceLearner = PreferenceLearner()
    private let scenarioGenerator = ScenarioGenerator()
    private let reoptimizer = IncrementalReoptimizer()

    // MARK: - State

    private(set) var isOptimizing = false
    private(set) var lastResult: OptimizerResult?
    private(set) var progress: GAProgress?

    /// The current schedule genes (movable events placement).
    private(set) var currentSchedule: [ScheduleGene] = []

    // MARK: - Configuration

    var gaConfig: GAConfiguration = .default
    var preferences: OptimizerPreferences = OptimizerPreferences()

    // MARK: - Full Optimization

    /// Run a full optimization for the given context.
    /// Returns multiple diverse scenarios for the user to choose from.
    func optimize(context: OptimizerContext) -> OptimizerResult {
        isOptimizing = true
        defer { isOptimizing = false }

        // Apply learned preferences
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

        let startTime = Date()

        let ga = GeneticAlgorithm<ScheduleChromosome>(
            config: gaConfig,
            context: adjustedContext,
            evaluate: { [evaluator, adjustedContext] chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: adjustedContext)
            },
            onProgress: { [weak self] p in
                self?.progress = p
            }
        )

        let population = ga.run()
        let duration = Date().timeIntervalSince(startTime)

        // Generate diverse scenarios
        let scenarios = scenarioGenerator.generateScenarios(
            from: population,
            context: adjustedContext,
            evaluator: evaluator
        )

        let metadata = OptimizationMetadata(
            generations: ga.convergenceGeneration,
            totalDuration: duration,
            bestFitness: population.first?.fitness ?? 0,
            averageFitness: population.prefix(10).reduce(0) { $0 + $1.fitness } / Double(min(10, population.count)),
            convergenceGeneration: ga.convergenceGeneration
        )

        let result = OptimizerResult(scenarios: scenarios, metadata: metadata)
        lastResult = result

        // Update current schedule with best result
        if let best = scenarios.first {
            currentSchedule = best.genes
        }

        return result
    }

    // MARK: - Quick Optimize (Day)

    /// Quick optimization for today only. Uses faster GA settings.
    func optimizeToday(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) -> OptimizerResult {
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

        let savedConfig = gaConfig
        gaConfig = .quick
        defer { gaConfig = savedConfig }

        return optimize(context: context)
    }

    // MARK: - Weekly Optimize

    /// Optimize the full week schedule.
    func optimizeWeek(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18,
        participantAvailability: [String: [DateInterval]] = [:]
    ) -> OptimizerResult {
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

        return optimize(context: context)
    }

    // MARK: - Incremental Re-optimization (#26)

    /// Re-optimize after a schedule change (new event, cancellation, etc.).
    func reoptimize(
        trigger: ReoptimizationTrigger,
        context: OptimizerContext
    ) -> OptimizerResult? {
        isOptimizing = true
        defer { isOptimizing = false }

        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let evaluator = FitnessEvaluator.standard(preferences: prefs)

        return reoptimizer.reoptimize(
            currentSchedule: currentSchedule,
            trigger: trigger,
            context: context,
            evaluator: evaluator,
            config: .quick
        )
    }

    // MARK: - User Feedback (#24)

    /// User accepted a scenario — record positive feedback.
    func acceptScenario(_ scenario: ScheduleScenario) {
        currentSchedule = scenario.genes
        preferenceLearner.recordAcceptance(scenarioFitness: scenario.fitness)
    }

    /// User rejected a scenario — record negative feedback.
    func rejectScenario(_ scenario: ScheduleScenario) {
        preferenceLearner.recordRejection(scenarioFitness: scenario.fitness)
    }

    /// User manually edited the schedule — record modification feedback.
    func recordManualEdit(original: [ScheduleGene], edited: [ScheduleGene]) {
        currentSchedule = edited
        preferenceLearner.recordModification(original: original, edited: edited)
    }

    // MARK: - Scenario Comparison (#27)

    /// Compare the scenarios from the last optimization.
    func compareLastScenarios() -> [ScenarioComparison] {
        guard let result = lastResult else { return [] }
        return scenarioGenerator.compareScenarios(result.scenarios)
    }

    // MARK: - Focus Block Suggestions (#1)

    /// Find optimal focus block placements in the current schedule.
    func suggestFocusBlocks(
        count: Int = 2,
        durationMinutes: Int = 120,
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) -> OptimizerResult {
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

        return optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: focusEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Pomodoro Optimization (#2)

    /// Find the optimal time for a Pomodoro session.
    func suggestPomodoroSlot(
        config: PomodoroConfig = .classic,
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) -> OptimizerResult {
        let totalMinutes = config.workMinutes * config.rounds
            + config.breakMinutes * (config.rounds - 1)
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

        return optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: [pomodoroEvent],
            workingHours: workingHours
        )
    }

    // MARK: - Meeting Scheduling (#5, #16)

    /// Find optimal slot for a meeting with participants.
    func suggestMeetingSlot(
        title: String,
        durationMinutes: Int,
        participants: [String],
        fixedEvents: [CalendarEvent],
        participantAvailability: [String: [DateInterval]],
        workingHours: ClosedRange<Int> = 9...18
    ) -> OptimizerResult {
        let meetingEvent = OptimizableEvent(
            title: title,
            duration: TimeInterval(durationMinutes * 60),
            priority: 0.9,
            context: "meeting",
            energyCost: 0.6,
            requiredParticipants: participants
        )

        return optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: [meetingEvent],
            workingHours: workingHours,
            participantAvailability: participantAvailability
        )
    }

    // MARK: - Day Planning (#6)

    /// Plan an entire day by placing all movable tasks optimally.
    func planDay(
        tasks: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) -> OptimizerResult {
        optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: tasks,
            workingHours: workingHours
        )
    }

    // MARK: - Week Balancing (#9)

    /// Rebalance the week by redistributing movable events across days.
    func balanceWeek(
        movableEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) -> OptimizerResult {
        optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Reset

    /// Reset all learned preferences and optimization state.
    func reset() {
        preferenceLearner.reset()
        currentSchedule = []
        lastResult = nil
        progress = nil
        preferences = OptimizerPreferences()
    }
}
