import Foundation
import BuboDomain

// MARK: - Optimizer Result

/// The output of a single optimization run.
public struct OptimizerResult: Sendable {

    public init(
        scenarios: [ScheduleScenario],
        metadata: OptimizationMetadata
    ) {
        self.scenarios = scenarios
        self.metadata = metadata
    }

    public let scenarios: [ScheduleScenario]
    public let metadata: OptimizationMetadata
}

public struct ScheduleScenario: Identifiable, Sendable {

    public init(
        genes: [ScheduleGene],
        fitness: Double,
        objectiveBreakdown: [String: Double],
        constraintViolations: [String],
        taskSequenceByDay: [Date: [String]]? = nil,
        sourceSignature: TaskSignature? = nil
    ) {
        self.genes = genes
        self.fitness = fitness
        self.objectiveBreakdown = objectiveBreakdown
        self.constraintViolations = constraintViolations
        self.taskSequenceByDay = taskSequenceByDay
        self.sourceSignature = sourceSignature
    }

    public let id = UUID()
    public let genes: [ScheduleGene]
    public let fitness: Double
    public let objectiveBreakdown: [String: Double]
    public let constraintViolations: [String]

    /// Optimized task execution order within each day's Pomodoro blocks.
    /// Keys are day start dates (normalized via `Calendar.startOfDay(for:)`);
    /// values are event IDs in recommended order.
    /// Populated by `planDayWithSequencing` — nil when sequencing wasn't applied.
    public var taskSequenceByDay: [Date: [String]]?

    /// Workload identity at the moment this scenario was produced.
    /// `BuboOptimizer.acceptScenario` / `rejectScenario` /
    /// `recordManualEdit` use this to route feedback into the
    /// correct per-workload learner bundle, even after subsequent
    /// optimizations on different workloads.
    /// `nil` for scenarios produced outside `BuboOptimizer` (e.g.
    /// hand-built fixtures).
    public var sourceSignature: TaskSignature?

    /// Genes actively placed in the schedule (excludes dropped droppable genes).
    public var activeGenes: [ScheduleGene] { genes.filter { $0.isIncluded } }

    /// Number of droppable tasks that the GA chose not to include.
    public var droppedCount: Int { genes.count { !$0.isIncluded && $0.isDroppable } }

    /// Convert genes back to CalendarEvents for display.
    /// Only includes active genes; optimizer-generated events default to movable.
    public func toCalendarEvents() -> [CalendarEvent] {
        activeGenes.map { gene in
            var event = CalendarEvent(
                id: gene.eventId,
                title: gene.title,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: nil,
                calendarName: "Optimizer",
                eventType: gene.pomodoroConfig != nil ? .pomodoro : .standard
            )
            event.isMovable = true
            event.isTask = gene.storyPoints != nil
            event.pomodoroConfig = gene.pomodoroConfig
            event.storyPoints = gene.storyPoints
            return event
        }
    }
}

public struct OptimizationMetadata: Sendable {

    public init(
        generations: Int,
        totalDuration: TimeInterval,
        bestFitness: Double,
        averageFitness: Double,
        convergenceGeneration: Int
    ) {
        self.generations = generations
        self.totalDuration = totalDuration
        self.bestFitness = bestFitness
        self.averageFitness = averageFitness
        self.convergenceGeneration = convergenceGeneration
    }

    public let generations: Int
    public let totalDuration: TimeInterval
    public let bestFitness: Double
    public let averageFitness: Double
    public let convergenceGeneration: Int
}

// MARK: - User Feedback

/// Tracks user actions on optimizer suggestions for preference learning.
public enum UserFeedback: Codable, Sendable {
    case accepted(scenarioFitness: Double, weights: [String: Double])
    case rejected(scenarioFitness: Double, weights: [String: Double])
    case modified(originalGenes: [ScheduleGene], editedGenes: [ScheduleGene], weights: [String: Double])
}
