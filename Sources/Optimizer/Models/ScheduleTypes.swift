import Foundation
import BuboDomain

// MARK: - Shared Schedule Types
//
// Types shared across the optimizer, intents, and UI.
// Extracted from the former ScheduleRecipe.swift — these are pure data types
// with no dependency on the recipe system.

// MARK: - Horizon

public enum Horizon: String, Codable, Hashable, CaseIterable, Sendable {
    case today
    case tomorrow
    case week
}

// MARK: - Speed

public enum Speed: String, Codable, Hashable, CaseIterable, Sendable {
    case quick
    case balanced
    case thorough

    public var gaConfiguration: GAConfiguration {
        switch self {
        case .quick: return .quick
        case .balanced: return .default
        case .thorough: return .thorough
        }
    }
}

// MARK: - Stability

public enum Stability: String, Codable, Hashable, CaseIterable, Sendable {
    case full
    case normal
    case conservative
}

// MARK: - Period
// Moved to `Sources/Domain/Calendar/Period.swift` on 2026-05-12 to break the
// Domain ↔ Optimizer dependency cycle (BacklogTask carries a `Period`).

// MARK: - Weight Key

public enum WeightKey: String, Codable, Hashable, CaseIterable, Sendable {
    case focusBlock
    case pomodoroFit
    case conflict
    case taskPlacement
    case weekBalance
    case energyCurve
    case multiPerson
    case breakPlacement = "break"
    case deadline
    case contextSwitch
    case buffer
    case useLearned = "_useLearned"
}

// MARK: - Hour Range

/// A start/end hour range (Codable replacement for tuple).
public struct HourRange: Codable, Hashable, Sendable {

    public init(
        start: Int,
        end: Int
    ) {
        self.start = start
        self.end = end
    }

    public var start: Int
    public var end: Int

    public var closedRange: ClosedRange<Int> { start...end }
}

// MARK: - Event Spec

/// Specification for creating synthetic events at execution time.
public struct EventSpec: Codable, Hashable, Sendable {
    public var specId: String = UUID().uuidString
    public var title: String = "Event"
    public var minutes: Int = 60
    public var count: Int = 1
    public var priority: Double = 0.5
    public var energy: Double = 0.5
    public var context: String? = nil
    public var period: Period? = nil
    public var focus: Bool = false
    /// Marks the spec as a pomodoro session that `IntentCompiler` must
    /// resolve into a concrete `pomodoroConfig` using live signals.
    public var autoPomodoro: Bool = false
    /// When set, `resolveAutoPomodoros` packs up to this many backlog
    /// tasks into the session (focus-burst behaviour). `nil` keeps the
    /// single-task `.pomodoroSession` path. Upper bound matches the
    /// resolver's `roundBounds.upperBound`.
    public var autoFocusBurstMax: Int? = nil
    /// Concrete pomodoro shape (work / break / rounds / long break).
    /// Populated by `PomodoroConfigResolver` during compilation — no fixed
    /// preset catalogue.
    public var pomodoroConfig: PomodoroConfig? = nil
    /// Backlog task ids consumed by this spec, in per-round order. Drives
    /// the strict "one pomodoro = these tasks" binding: `IntentCompiler`
    /// fills it during resolution, `collectBacklogTasks` filters those
    /// ids out, and `OptimizerService.applyScenario` uses it to populate
    /// `CalendarEvent.pomodoroTaskSequence` and call `markScheduled` for
    /// every task in the list.
    public var reservedTaskIds: [String] = []
    public var participants: [String] = []
    public var creation: CreationMode = .fixed
    public var chainGap: Int? = nil
    public var segments: [EventSegment]? = nil
    public var startOffsetMinutes: Int? = nil
    public var storyPoints: Int? = nil
    public var deadline: Date? = nil
    public var dependsOn: [String] = []

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        specId = (try? c.decode(String.self, forKey: .specId)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? "Event"
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 60
        count = (try? c.decode(Int.self, forKey: .count)) ?? 1
        priority = (try? c.decode(Double.self, forKey: .priority)) ?? 0.5
        energy = (try? c.decode(Double.self, forKey: .energy)) ?? 0.5
        context = try? c.decode(String.self, forKey: .context)
        period = try? c.decode(Period.self, forKey: .period)
        focus = (try? c.decode(Bool.self, forKey: .focus)) ?? false
        autoPomodoro = (try? c.decode(Bool.self, forKey: .autoPomodoro)) ?? false
        autoFocusBurstMax = try? c.decode(Int.self, forKey: .autoFocusBurstMax)
        pomodoroConfig = try? c.decode(PomodoroConfig.self, forKey: .pomodoroConfig)
        reservedTaskIds = (try? c.decode([String].self, forKey: .reservedTaskIds)) ?? []
        participants = (try? c.decode([String].self, forKey: .participants)) ?? []
        creation = (try? c.decode(CreationMode.self, forKey: .creation)) ?? .fixed
        chainGap = try? c.decode(Int.self, forKey: .chainGap)
        segments = try? c.decode([EventSegment].self, forKey: .segments)
        startOffsetMinutes = try? c.decode(Int.self, forKey: .startOffsetMinutes)
        storyPoints = try? c.decode(Int.self, forKey: .storyPoints)
        deadline = try? c.decode(Date.self, forKey: .deadline)
        dependsOn = (try? c.decode([String].self, forKey: .dependsOn)) ?? []
    }

    public init(
        specId: String = UUID().uuidString,
        title: String = "Event",
        minutes: Int = 60,
        count: Int = 1,
        priority: Double = 0.5,
        energy: Double = 0.5,
        context: String? = nil,
        period: Period? = nil,
        focus: Bool = false,
        autoPomodoro: Bool = false,
        autoFocusBurstMax: Int? = nil,
        pomodoroConfig: PomodoroConfig? = nil,
        reservedTaskIds: [String] = [],
        participants: [String] = [],
        creation: CreationMode = .fixed,
        chainGap: Int? = nil,
        segments: [EventSegment]? = nil,
        startOffsetMinutes: Int? = nil,
        storyPoints: Int? = nil,
        deadline: Date? = nil,
        dependsOn: [String] = []
    ) {
        self.specId = specId
        self.title = title
        self.minutes = minutes
        self.count = count
        self.priority = priority
        self.energy = energy
        self.context = context
        self.period = period
        self.focus = focus
        self.autoPomodoro = autoPomodoro
        self.autoFocusBurstMax = autoFocusBurstMax
        self.pomodoroConfig = pomodoroConfig
        self.reservedTaskIds = reservedTaskIds
        self.participants = participants
        self.creation = creation
        self.chainGap = chainGap
        self.segments = segments
        self.startOffsetMinutes = startOffsetMinutes
        self.storyPoints = storyPoints
        self.deadline = deadline
        self.dependsOn = dependsOn
    }
}

// MARK: - Event Segment

public struct EventSegment: Codable, Hashable, Sendable {
    public var title: String
    public var minutes: Int
    public var type: SegmentType = .work

    public init(title: String, minutes: Int, type: SegmentType = .work) {
        self.title = title
        self.minutes = minutes
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        minutes = try c.decode(Int.self, forKey: .minutes)
        type = (try? c.decode(SegmentType.self, forKey: .type)) ?? .work
    }
}

public enum SegmentType: String, Codable, Hashable, CaseIterable, Sendable {
    case work
    case rest
    case transition
}

// MARK: - Creation Mode

public enum CreationMode: Codable, Hashable, Sendable {
    case fixed
    case fillGaps
    case fromUnfinished
    case splitEvent(String)
}

// MARK: - Event Match

/// Selects which existing events a rule applies to.
public enum EventMatch: Codable, Hashable, Sendable {
    case all
    case context(String)
    case focusBlocks
    case meetings
    case highEnergy
    case lowEnergy
    case withDeadline
    case longerThan(minutes: Int)
    case id(String)
    case ids([String])
    case onDay(Int)
    case onDays([Int])
}

// MARK: - Schedule Snapshot

/// Lightweight snapshot of what the optimizer saw when it failed.
public struct ScheduleSnapshot: Sendable {

    public init(
        freeGaps: [DateInterval],
        workingHours: ClosedRange<Int>,
        planningHorizon: DateInterval
    ) {
        self.freeGaps = freeGaps
        self.workingHours = workingHours
        self.planningHorizon = planningHorizon
    }

    public let freeGaps: [DateInterval]
    public let workingHours: ClosedRange<Int>
    public let planningHorizon: DateInterval
}

// MARK: - Applied Snapshot (for Undo)

/// Prior link state of one backlog task touched by an apply, keyed by
/// *task id* — the same key `markScheduled`/`unschedule` use. Undo must
/// restore links by this key: gene event ids are NOT task ids for focus
/// blocks (`reservedTaskIds`) or chunked tasks (`groupId` + `_pN`
/// suffixes), so an event-id-keyed rollback silently strands tasks in
/// `.scheduled`.
public struct BacklogLinkSnapshot: Codable, Sendable {

    public init(
        taskId: String,
        scheduledEventIds: [String],
        scheduledDate: Date?
    ) {
        self.taskId = taskId
        self.scheduledEventIds = scheduledEventIds
        self.scheduledDate = scheduledDate
    }

    public let taskId: String
    /// Empty = the task was unscheduled (pending) before the apply.
    public let scheduledEventIds: [String]
    public let scheduledDate: Date?
}

public struct AppliedSnapshot: Codable, Sendable {

    public init(
        requestName: String,
        appliedAt: Date,
        previousGenes: [ScheduleGene],
        appliedGenes: [ScheduleGene],
        createdEventIds: [String],
        removedEvents: [CalendarEvent] = [],
        previousTaskLinks: [BacklogLinkSnapshot] = []
    ) {
        self.requestName = requestName
        self.appliedAt = appliedAt
        self.previousGenes = previousGenes
        self.appliedGenes = appliedGenes
        self.createdEventIds = createdEventIds
        self.removedEvents = removedEvents
        self.previousTaskLinks = previousTaskLinks
    }

    public let requestName: String
    public let appliedAt: Date
    public let previousGenes: [ScheduleGene]
    public let appliedGenes: [ScheduleGene]
    public let createdEventIds: [String]
    /// Local calendar events the apply deleted (prior chunks of
    /// rescheduled tasks). Undo re-adds them — without this, an
    /// apply-then-undo permanently loses them while `previousGenes`
    /// still claims they exist.
    public let removedEvents: [CalendarEvent]
    /// Link state of every backlog task the apply re-linked, captured
    /// before `markScheduled` overwrote it.
    public let previousTaskLinks: [BacklogLinkSnapshot]
}

// MARK: - Energy Adjustment
//
// `adjustedEnergy(base:storyPoints:)` lives in `BuboDomain` so that
// `BacklogTask.toOptimizableEvent()` can call it without an upward
// dependency. Importing `BuboDomain` here re-exports it to existing
// callers in this target.
