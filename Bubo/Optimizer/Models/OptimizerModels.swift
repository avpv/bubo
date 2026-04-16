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
    let dependsOn: [String]         // IDs of tasks that must finish first
    let isDroppable: Bool           // GA can exclude this event if it doesn't fit

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
        storyPoints: Int? = nil,
        dependsOn: [String] = [],
        isDroppable: Bool = false
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
        self.dependsOn = dependsOn
        self.isDroppable = isDroppable
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
    let isDroppable: Bool           // whether the GA may exclude this gene
    var isIncluded: Bool            // whether this gene is active in the schedule

    /// Frozen-region flag. When true, the gene is pinned at its current
    /// `startTime` — `mutate()` skips it, `repair()` ignores it for
    /// relocation (but still uses it as an overlap constraint for other
    /// genes), and crossover preserves the locked slot rather than swapping
    /// in a partner's value. Populated by `IncrementalReoptimizer` for
    /// ruin-and-recreate reflows where only a subset of events should
    /// move. Default `false` keeps prior behaviour intact.
    var isLocked: Bool

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
        storyPoints: Int? = nil,
        isDroppable: Bool = false,
        isIncluded: Bool = true,
        isLocked: Bool = false
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
        self.isDroppable = isDroppable
        self.isIncluded = isIncluded
        self.isLocked = isLocked
    }

    /// Create a copy with a new start time (preserves all other fields).
    /// Locked genes return `self` unchanged — reflects the pin semantics
    /// at the value-type level so callers can't accidentally move them.
    func withStartTime(_ newStart: Date) -> ScheduleGene {
        guard !isLocked else { return self }
        return ScheduleGene(
            eventId: eventId,
            title: title,
            startTime: newStart,
            duration: duration,
            context: context,
            energyCost: energyCost,
            priority: priority,
            isFocusBlock: isFocusBlock,
            storyPoints: storyPoints,
            isDroppable: isDroppable,
            isIncluded: isIncluded,
            isLocked: isLocked
        )
    }
}

// MARK: - Optimizer Context

/// All data the optimizer needs to generate and evaluate schedules.
///
/// Note on determinism: `rng` is a reference-typed `GARandom` shared across
/// every operator (mutation, crossover, selection, …) during a run. Passing
/// a seeded RNG makes the whole optimization reproducible, which is what the
/// benchmark/regression suite relies on. Default is `GARandom()` with a
/// system-derived seed so production runs stay non-repetitive while still
/// being internally deterministic (the seed is recoverable via `rng.seed`
/// for replaying a failing run).
struct OptimizerContext: Sendable {
    let fixedEvents: [CalendarEvent]
    let movableEvents: [OptimizableEvent]
    let workingHours: ClosedRange<Int>              // e.g. 9...18
    let planningHorizon: DateInterval
    let preferences: OptimizerPreferences
    let participantAvailability: [String: [DateInterval]]  // participantId -> free slots
    let calendar: Calendar
    let rng: GARandom

    /// Optional adaptive operator selector. When set, `ScheduleChromosome.mutate`
    /// consults it to pick a mutation operator per call instead of rolling
    /// uniformly. Shared across every mutation in a single run so the arm
    /// reward statistics accumulate.
    let mutationBandit: MutationBandit?

    /// Optional contextual (LinUCB-style) bandit. When set, it supersedes
    /// `mutationBandit` for operator selection: features like diversity,
    /// generation progress, and conflict rate are passed in, and the bandit
    /// picks an operator conditional on that landscape state. Nil = use
    /// the simpler stateless `mutationBandit` (or uniform random when both
    /// are nil). Shared across a run the same way `mutationBandit` is.
    let contextualBandit: ContextualBandit?

    /// Optional novelty archive. When present, the GA's effective fitness
    /// blends rawFitness with a k-NN novelty score in behaviour-descriptor
    /// space (see `NoveltyArchive`). Nil = pure fitness selection.
    let noveltyArchive: NoveltyArchive?

    /// Optional Quality-Diversity archive. Every evaluated chromosome is
    /// offered for archival; initial populations can pull warm-start elites
    /// from it via `MAPElitesArchive.sampleSeeds`. Nil = single-best GA.
    let mapElitesArchive: MAPElitesArchive?

    /// Optional surrogate model used by Surrogate-Assisted Evolution. When
    /// set, the GA pre-filters offspring through the surrogate before full
    /// evaluation; only top-K by predicted fitness + a small exploration
    /// bonus are sent to the real evaluator. Nil = evaluate everything
    /// (pre-existing behaviour).
    let surrogate: FitnessSurrogate?

    /// Optional experience archive — a persistent store of high-fitness
    /// chromosomes keyed by workload signature, consulted for warm-start
    /// seeding at the beginning of a new run. Nil = cold start every time.
    let experienceArchive: ExperienceArchive?

    /// Optional multi-fidelity evaluator. When set *and* the GA config
    /// opts into `useMultiFidelity`, early generations score offspring
    /// through the cheap proxy and only promote the top fraction to
    /// full evaluation.
    let multiFidelityEvaluator: MultiFidelityEvaluator?

    /// Optional REINFORCE-style neural policy over mutation operators.
    /// Takes precedence over the two bandits when
    /// `GAConfiguration.useNeuralPolicy` is on. Nil = bandit / uniform
    /// routes stay in charge.
    let neuralOperatorPolicy: NeuralOperatorPolicy?

    /// Optional specialised repair strategy. When the GA produces an
    /// offspring that `ConstraintEngine` still rejects after the
    /// built-in `ScheduleChromosome.repair`, we hand it to this
    /// repairer. Defaults to the quick heuristic chain when nil.
    let scheduleRepairer: ScheduleRepairer?

    /// Back-reference to the evaluator currently driving the run. Used
    /// by the progressive-eval pruning pass inside
    /// `GeneticAlgorithm.evolveOneGeneration` — it needs to call
    /// `progressiveEvaluate` against the same objective configuration
    /// that produced the main fitness readings. Optional because not
    /// every caller wires one; when nil the progressive-eval path is
    /// skipped even if `GAConfiguration.useProgressiveEvaluation` is on.
    let fitnessEvaluator: FitnessEvaluator?

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
        calendar: Calendar = .current,
        rng: GARandom = GARandom(),
        mutationBandit: MutationBandit? = nil,
        contextualBandit: ContextualBandit? = nil,
        noveltyArchive: NoveltyArchive? = nil,
        mapElitesArchive: MAPElitesArchive? = nil,
        surrogate: FitnessSurrogate? = nil,
        experienceArchive: ExperienceArchive? = nil,
        multiFidelityEvaluator: MultiFidelityEvaluator? = nil,
        neuralOperatorPolicy: NeuralOperatorPolicy? = nil,
        scheduleRepairer: ScheduleRepairer? = nil,
        fitnessEvaluator: FitnessEvaluator? = nil
    ) {
        self.fixedEvents = fixedEvents
        self.movableEvents = movableEvents
        self.workingHours = workingHours
        self.planningHorizon = planningHorizon
        self.preferences = preferences
        self.participantAvailability = participantAvailability
        self.calendar = calendar
        self.rng = rng
        self.mutationBandit = mutationBandit
        self.contextualBandit = contextualBandit
        self.noveltyArchive = noveltyArchive
        self.mapElitesArchive = mapElitesArchive
        self.surrogate = surrogate
        self.experienceArchive = experienceArchive
        self.multiFidelityEvaluator = multiFidelityEvaluator
        self.neuralOperatorPolicy = neuralOperatorPolicy
        self.scheduleRepairer = scheduleRepairer
        self.fitnessEvaluator = fitnessEvaluator
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
    var taskInclusionWeight: Double

    // Energy model
    var peakEnergyHour: Int           // hour of day with peak energy
    var energyDecayRate: Double       // how fast energy drops
    /// Personal energy curve from check-in data (24 values, 0…1 per hour).
    /// nil = use static Gaussian centred on peakEnergyHour.
    var personalEnergyCurve: [Double]?

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
        taskInclusionWeight: Double = 4.0,
        peakEnergyHour: Int = 10,
        energyDecayRate: Double = 0.1,
        personalEnergyCurve: [Double]? = nil,
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
        self.taskInclusionWeight = taskInclusionWeight
        self.peakEnergyHour = peakEnergyHour
        self.energyDecayRate = energyDecayRate
        self.personalEnergyCurve = personalEnergyCurve
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

    /// Genes actively placed in the schedule (excludes dropped droppable genes).
    var activeGenes: [ScheduleGene] { genes.filter { $0.isIncluded } }

    /// Number of droppable tasks that the GA chose not to include.
    var droppedCount: Int { genes.count { !$0.isIncluded && $0.isDroppable } }

    /// Convert genes back to CalendarEvents for display.
    /// Only includes active genes; optimizer-generated events default to movable.
    func toCalendarEvents() -> [CalendarEvent] {
        activeGenes.map { gene in
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
