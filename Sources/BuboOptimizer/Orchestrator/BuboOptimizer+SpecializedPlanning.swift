import Foundation
import BuboDomain

// MARK: - BuboOptimizer specialized planning entry points
//
// Single-purpose façade methods that build a one-off `OptimizerContext`
// for a specific planning shape (a focus block, a meeting window, a
// single day, a pomodoro sequence, a week-balance pass, …) and delegate
// to the main `optimize(...)` pipeline. Extracted from `BuboOptimizer.swift`
// so the main file stays focused on the GA-driven optimization core; these
// methods read as parameter-shaping shims and don't share private helpers
// with the main pipeline.

public extension BuboOptimizer {

    // MARK: - Focus Block Suggestions (#1)

    public func suggestFocusBlocks(
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

    // MARK: - Meeting Scheduling (#5, #16)

    public func suggestMeetingSlot(
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
    public func optimizePomodoroSequence(
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

    public func planDay(
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

    // MARK: - Day Planning with Pomodoro Sequencing

    /// Two-phase optimization:
    /// 1. Schedule GA places tasks in optimal time slots
    /// 2. Sequence GA optimizes task execution order within each day
    ///
    /// The result includes `taskSequenceByDay` on each scenario, indicating
    /// the recommended execution order for tasks grouped on the same day.
    public func planDayWithSequencing(
        tasks: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18,
        sequenceWeights: PomodoroSequenceEvaluator.Weights = .default
    ) async -> OptimizerResult {
        // Phase 1: place tasks in time slots
        var result = await planDay(
            tasks: tasks,
            fixedEvents: fixedEvents,
            workingHours: workingHours
        )

        // Phase 2: optimize task order within each day per scenario
        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let cal = Calendar.current
        let capturedPrefs = preferences
        let capturedWeights = sequenceWeights

        // Build all sequence optimization work items across all scenarios
        public struct SequenceJob: Sendable {

            public init(
                scenarioIndex: Int,
                day: Date,
                tasks: [OptimizableEvent],
                sessionStart: Date
            ) {
                self.scenarioIndex = scenarioIndex
                self.day = day
                self.tasks = tasks
                self.sessionStart = sessionStart
            }

            public let scenarioIndex: Int
            public let day: Date
            public let tasks: [OptimizableEvent]
            public let sessionStart: Date
        }

        var jobs: [SequenceJob] = []
        var trivialSequences: [(scenarioIndex: Int, day: Date, eventIds: [String])] = []

        for (scenarioIndex, scenario) in result.scenarios.enumerated() {
            var genesByDay: [Date: [ScheduleGene]] = [:]
            for gene in scenario.genes {
                let day = cal.startOfDay(for: gene.startTime)
                genesByDay[day, default: []].append(gene)
            }

            for (day, dayGenes) in genesByDay {
                let dayTasks = dayGenes.compactMap { taskMap[$0.eventId] }
                if dayTasks.count > 1 {
                    let sessionStart = dayGenes.map(\.startTime).min() ?? day
                    jobs.append(SequenceJob(
                        scenarioIndex: scenarioIndex,
                        day: day,
                        tasks: dayTasks,
                        sessionStart: sessionStart
                    ))
                } else {
                    trivialSequences.append((scenarioIndex, day, dayGenes.map(\.eventId)))
                }
            }
        }

        // Spawn all sequence optimizations in parallel
        let parallelTasks = jobs.map { job in
            (job, Task.detached(priority: .userInitiated) {
                PomodoroSequenceOptimizer.optimize(
                    tasks: job.tasks,
                    sessionStart: job.sessionStart,
                    preferences: capturedPrefs,
                    config: .quick,
                    weights: capturedWeights
                )
            })
        }

        // Collect results
        var sequencesByScenario: [Int: [Date: [String]]] = [:]
        for (scenarioIndex, day, eventIds) in trivialSequences {
            sequencesByScenario[scenarioIndex, default: [:]][day] = eventIds
        }

        // Await all parallel tasks
        for (job, task) in parallelTasks {
            let ordered = await task.value
            sequencesByScenario[job.scenarioIndex, default: [:]][job.day] = ordered.map(\.id)
        }

        // Build enhanced scenarios
        let enhancedScenarios = result.scenarios.enumerated().map { (idx, scenario) -> ScheduleScenario in
            var enhanced = scenario
            enhanced.taskSequenceByDay = sequencesByScenario[idx]
            return enhanced
        }

        result = OptimizerResult(
            scenarios: enhancedScenarios,
            metadata: result.metadata
        )
        lastResult = result
        return result
    }

    // MARK: - Meeting Clustering

    /// Optimize meeting placement to cluster meetings together,
    /// maximizing continuous focus blocks during the rest of the day.
    public func clusterMeetings(
        meetings: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        // Boost clustering weight for this specific optimization
        var prefs = preferences
        prefs.meetingClusteringWeight = max(prefs.meetingClusteringWeight, 2.0)
        prefs.focusBlockWeight = max(prefs.focusBlockWeight, 1.5)

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents.filter { $0.startDate >= todayStart && $0.startDate < todayEnd },
            movableEvents: meetings,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: max(Date(), todayStart), end: todayEnd),
            preferences: prefs
        )

        return await optimize(context: context, overrideConfig: .quick, overrideIslandConfig: .quick)
    }

    // MARK: - Week Balancing (#9)

    public func balanceWeek(
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
}
