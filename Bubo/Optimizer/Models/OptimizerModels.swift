import Foundation

// MARK: - Optimizable Event

/// An event that the optimizer can move around in the schedule.
struct OptimizableEvent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let duration: TimeInterval
    let deadline: Date?
    let priority: Double            // 0…1, higher = more important
    let context: String?            // project / category tag
    let energyCost: Double          // 0…1, cognitive load
    let requiredParticipants: [String]
    let preferredHourRange: ClosedRange<Int>?  // e.g. 9...12
    let isFocusBlock: Bool
    let pomodoroConfig: PomodoroConfig?
    let earliestStart: Date?        // don't schedule before this time
    let storyPoints: Int?           // effort estimate (1, 2, 3, 5, 8, 13)

    init(
        id: String = UUID().uuidString,
        title: String,
        duration: TimeInterval,
        deadline: Date? = nil,
        priority: Double = 0.5,
        context: String? = nil,
        energyCost: Double = 0.5,
        requiredParticipants: [String] = [],
        preferredHourRange: ClosedRange<Int>? = nil,
        isFocusBlock: Bool = false,
        pomodoroConfig: PomodoroConfig? = nil,
        earliestStart: Date? = nil,
        storyPoints: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.duration = duration
        self.deadline = deadline
        self.priority = priority
        self.context = context
        self.energyCost = energyCost
        self.requiredParticipants = requiredParticipants
        self.preferredHourRange = preferredHourRange
        self.isFocusBlock = isFocusBlock
        self.pomodoroConfig = pomodoroConfig
        self.earliestStart = earliestStart
        self.storyPoints = storyPoints
    }
}

// MARK: - Pomodoro Config

struct PomodoroConfig: Codable, Hashable, Sendable {
    let workMinutes: Int
    let breakMinutes: Int
    let rounds: Int
    let longBreakMinutes: Int

    static let classic = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 15)
    static let deepWork = PomodoroConfig(workMinutes: 50, breakMinutes: 10, rounds: 2, longBreakMinutes: 20)
}

// MARK: - Schedule Gene

/// A single gene: placement of one event in the schedule.
struct ScheduleGene: Codable, Hashable, Sendable {
    let eventId: String
    let title: String
    var startTime: Date
    let duration: TimeInterval
    let context: String?
    let energyCost: Double
    let priority: Double
    let isFocusBlock: Bool
    let storyPoints: Int?

    var endTime: Date { startTime.addingTimeInterval(duration) }

    init(
        eventId: String,
        title: String,
        startTime: Date,
        duration: TimeInterval,
        context: String?,
        energyCost: Double,
        priority: Double,
        isFocusBlock: Bool,
        storyPoints: Int? = nil
    ) {
        self.eventId = eventId
        self.title = title
        self.startTime = startTime
        self.duration = duration
        self.context = context
        self.energyCost = energyCost
        self.priority = priority
        self.isFocusBlock = isFocusBlock
        self.storyPoints = storyPoints
    }

    /// Create a copy with a new start time (preserves all other fields).
    func withStartTime(_ newStart: Date) -> ScheduleGene {
        ScheduleGene(
            eventId: eventId,
            title: title,
            startTime: newStart,
            duration: duration,
            context: context,
            energyCost: energyCost,
            priority: priority,
            isFocusBlock: isFocusBlock,
            storyPoints: storyPoints
        )
    }
}

// MARK: - Optimizer Context

/// All data the optimizer needs to generate and evaluate schedules.
struct OptimizerContext: Sendable {
    let fixedEvents: [CalendarEvent]
    let movableEvents: [OptimizableEvent]
    let workingHours: ClosedRange<Int>              // e.g. 9...18
    let planningHorizon: DateInterval
    let preferences: OptimizerPreferences
    let participantAvailability: [String: [DateInterval]]  // participantId -> free slots
    let calendar: Calendar

    init(
        fixedEvents: [CalendarEvent] = [],
        movableEvents: [OptimizableEvent] = [],
        workingHours: ClosedRange<Int> = 9...18,
        planningHorizon: DateInterval = DateInterval(
            start: Date(),
            duration: 7 * 24 * 3600
        ),
        preferences: OptimizerPreferences = OptimizerPreferences(),
        participantAvailability: [String: [DateInterval]] = [:],
        calendar: Calendar = .current
    ) {
        self.fixedEvents = fixedEvents
        self.movableEvents = movableEvents
        self.workingHours = workingHours
        self.planningHorizon = planningHorizon
        self.preferences = preferences
        self.participantAvailability = participantAvailability
        self.calendar = calendar
    }
}

// MARK: - Optimizer Preferences

/// User preferences that influence optimization weights.
struct OptimizerPreferences: Codable, Sendable {
    var focusBlockWeight: Double
    var pomodoroFitWeight: Double
    var conflictWeight: Double
    var taskPlacementWeight: Double
    var weekBalanceWeight: Double
    var energyCurveWeight: Double
    var multiPersonWeight: Double
    var breakWeight: Double
    var deadlineWeight: Double
    var contextSwitchWeight: Double
    var bufferWeight: Double
    var meetingClusteringWeight: Double

    // Energy model
    var peakEnergyHour: Int           // hour of day with peak energy
    var energyDecayRate: Double       // how fast energy drops

    // Break rules
    var maxConsecutiveMeetingMinutes: Int
    var minBreakMinutes: Int
    var lunchWindowStart: Int         // hour
    var lunchWindowEnd: Int           // hour

    // Buffer rules
    var defaultBufferMinutes: Int
    var heavyMeetingBufferMinutes: Int

    // Balance
    var maxMeetingsPerDay: Int
    var idealFocusBlockMinutes: Int

    // Meeting clustering
    var preferredClusterWindowStart: Int     // hour — meetings clustered after this
    var preferredClusterWindowEnd: Int       // hour — meetings clustered before this
    var maxMeetingsPerCluster: Int           // avoid marathon meeting blocks

    init(
        focusBlockWeight: Double = 1.0,
        pomodoroFitWeight: Double = 0.8,
        conflictWeight: Double = 10.0,      // high penalty
        taskPlacementWeight: Double = 1.0,
        weekBalanceWeight: Double = 0.8,
        energyCurveWeight: Double = 0.9,
        multiPersonWeight: Double = 5.0,    // high priority
        breakWeight: Double = 1.2,
        deadlineWeight: Double = 3.0,       // important
        contextSwitchWeight: Double = 0.7,
        bufferWeight: Double = 0.6,
        meetingClusteringWeight: Double = 0.8,
        peakEnergyHour: Int = 10,
        energyDecayRate: Double = 0.1,
        maxConsecutiveMeetingMinutes: Int = 120,
        minBreakMinutes: Int = 10,
        lunchWindowStart: Int = 12,
        lunchWindowEnd: Int = 14,
        defaultBufferMinutes: Int = 5,
        heavyMeetingBufferMinutes: Int = 15,
        maxMeetingsPerDay: Int = 6,
        idealFocusBlockMinutes: Int = 120,
        preferredClusterWindowStart: Int = 9,
        preferredClusterWindowEnd: Int = 13,
        maxMeetingsPerCluster: Int = 4
    ) {
        self.focusBlockWeight = focusBlockWeight
        self.pomodoroFitWeight = pomodoroFitWeight
        self.conflictWeight = conflictWeight
        self.taskPlacementWeight = taskPlacementWeight
        self.weekBalanceWeight = weekBalanceWeight
        self.energyCurveWeight = energyCurveWeight
        self.multiPersonWeight = multiPersonWeight
        self.breakWeight = breakWeight
        self.deadlineWeight = deadlineWeight
        self.contextSwitchWeight = contextSwitchWeight
        self.bufferWeight = bufferWeight
        self.meetingClusteringWeight = meetingClusteringWeight
        self.peakEnergyHour = peakEnergyHour
        self.energyDecayRate = energyDecayRate
        self.maxConsecutiveMeetingMinutes = maxConsecutiveMeetingMinutes
        self.minBreakMinutes = minBreakMinutes
        self.lunchWindowStart = lunchWindowStart
        self.lunchWindowEnd = lunchWindowEnd
        self.defaultBufferMinutes = defaultBufferMinutes
        self.heavyMeetingBufferMinutes = heavyMeetingBufferMinutes
        self.maxMeetingsPerDay = maxMeetingsPerDay
        self.idealFocusBlockMinutes = idealFocusBlockMinutes
        self.preferredClusterWindowStart = preferredClusterWindowStart
        self.preferredClusterWindowEnd = preferredClusterWindowEnd
        self.maxMeetingsPerCluster = maxMeetingsPerCluster
    }
}

// MARK: - Optimizer Result

/// The output of a single optimization run.
struct OptimizerResult: Sendable {
    let scenarios: [ScheduleScenario]
    let metadata: OptimizationMetadata
}

struct ScheduleScenario: Identifiable, Sendable {
    let id = UUID()
    let genes: [ScheduleGene]
    let fitness: Double
    let objectiveBreakdown: [String: Double]
    let constraintViolations: [String]

    /// Optimized task execution order within each day's Pomodoro blocks.
    /// Keys are day start dates (normalized via `Calendar.startOfDay(for:)`);
    /// values are event IDs in recommended order.
    /// Populated by `planDayWithSequencing` — nil when sequencing wasn't applied.
    var taskSequenceByDay: [Date: [String]]?

    /// Convert genes back to CalendarEvents for display.
    /// Optimizer-generated events default to movable for re-optimization.
    func toCalendarEvents() -> [CalendarEvent] {
        genes.map { gene in
            var event = CalendarEvent(
                id: gene.eventId,
                title: gene.title,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: nil,
                calendarName: "Optimizer",
                eventType: .standard
            )
            event.isMovable = true
            event.isTask = gene.storyPoints != nil
            event.storyPoints = gene.storyPoints
            return event
        }
    }
}

struct OptimizationMetadata: Sendable {
    let generations: Int
    let totalDuration: TimeInterval
    let bestFitness: Double
    let averageFitness: Double
    let convergenceGeneration: Int
}

// MARK: - User Feedback

/// Tracks user actions on optimizer suggestions for preference learning.
enum UserFeedback: Codable, Sendable {
    case accepted(scenarioFitness: Double, weights: [String: Double])
    case rejected(scenarioFitness: Double, weights: [String: Double])
    case modified(originalGenes: [ScheduleGene], editedGenes: [ScheduleGene], weights: [String: Double])
}
