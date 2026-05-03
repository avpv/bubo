import Foundation

// MARK: - Shared Schedule Types
//
// Types shared across the optimizer, intents, and UI.
// Extracted from the former ScheduleRecipe.swift — these are pure data types
// with no dependency on the recipe system.

// MARK: - Horizon

enum Horizon: String, Codable, Hashable, CaseIterable, Sendable {
    case today
    case tomorrow
    case week
}

// MARK: - Speed

enum Speed: String, Codable, Hashable, CaseIterable, Sendable {
    case quick
    case balanced
    case thorough

    var gaConfiguration: GAConfiguration {
        switch self {
        case .quick: return .quick
        case .balanced: return .default
        case .thorough: return .thorough
        }
    }
}

// MARK: - Stability

enum Stability: String, Codable, Hashable, CaseIterable, Sendable {
    case full
    case normal
    case conservative
}

// MARK: - Period

enum Period: String, Codable, Hashable, CaseIterable, Sendable {
    case night
    case morning
    case afternoon
    case evening

    var hourRange: ClosedRange<Int> {
        switch self {
        case .night: return 0...6
        case .morning: return 6...12
        case .afternoon: return 12...18
        case .evening: return 18...23
        }
    }

    /// Short human label used by pill controls and accessibility hints.
    /// Keeps the vocabulary consistent wherever the period surfaces.
    var displayLabel: String {
        switch self {
        case .night: return "Night"
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        }
    }
}

// MARK: - Weight Key

enum WeightKey: String, Codable, Hashable, CaseIterable, Sendable {
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
struct HourRange: Codable, Hashable, Sendable {
    var start: Int
    var end: Int

    var closedRange: ClosedRange<Int> { start...end }
}

// MARK: - Event Spec

/// Specification for creating synthetic events at execution time.
struct EventSpec: Codable, Hashable, Sendable {
    var specId: String = UUID().uuidString
    var title: String = "Event"
    var minutes: Int = 60
    var count: Int = 1
    var priority: Double = 0.5
    var energy: Double = 0.5
    var context: String? = nil
    var period: Period? = nil
    var focus: Bool = false
    /// Marks the spec as a pomodoro session that `IntentCompiler` must
    /// resolve into a concrete `pomodoroConfig` using live signals.
    var autoPomodoro: Bool = false
    /// When set, `resolveAutoPomodoros` packs up to this many backlog
    /// tasks into the session (focus-burst behaviour). `nil` keeps the
    /// single-task `.pomodoroSession` path. Upper bound matches the
    /// resolver's `roundBounds.upperBound`.
    var autoFocusBurstMax: Int? = nil
    /// Concrete pomodoro shape (work / break / rounds / long break).
    /// Populated by `PomodoroConfigResolver` during compilation — no fixed
    /// preset catalogue.
    var pomodoroConfig: PomodoroConfig? = nil
    /// Backlog task ids consumed by this spec, in per-round order. Drives
    /// the strict "one pomodoro = these tasks" binding: `IntentCompiler`
    /// fills it during resolution, `collectBacklogTasks` filters those
    /// ids out, and `OptimizerService.applyScenario` uses it to populate
    /// `CalendarEvent.pomodoroTaskSequence` and call `markScheduled` for
    /// every task in the list.
    var reservedTaskIds: [String] = []
    var participants: [String] = []
    var creation: CreationMode = .fixed
    var chainGap: Int? = nil
    var segments: [EventSegment]? = nil
    var startOffsetMinutes: Int? = nil
    var storyPoints: Int? = nil
    var deadline: Date? = nil
    var dependsOn: [String] = []

    init(from decoder: Decoder) throws {
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

    init(
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

struct EventSegment: Codable, Hashable, Sendable {
    var title: String
    var minutes: Int
    var type: SegmentType = .work

    init(title: String, minutes: Int, type: SegmentType = .work) {
        self.title = title
        self.minutes = minutes
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        minutes = try c.decode(Int.self, forKey: .minutes)
        type = (try? c.decode(SegmentType.self, forKey: .type)) ?? .work
    }
}

enum SegmentType: String, Codable, Hashable, CaseIterable, Sendable {
    case work
    case rest
    case transition
}

// MARK: - Creation Mode

enum CreationMode: Codable, Hashable, Sendable {
    case fixed
    case fillGaps
    case fromUnfinished
    case splitEvent(String)
}

// MARK: - Event Match

/// Selects which existing events a rule applies to.
enum EventMatch: Codable, Hashable, Sendable {
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
struct ScheduleSnapshot: Sendable {
    let freeGaps: [DateInterval]
    let workingHours: ClosedRange<Int>
    let planningHorizon: DateInterval
}

// MARK: - Actionable Resolution

/// An actionable resolution generated when a schedule fails.
struct ActionableResolution: Sendable, Identifiable {
    let id = UUID()
    let title: String
    let modifier: OptimizationRequest
}

// MARK: - Optimization Result Wrapper

/// Result of running the optimizer through any entry point.
enum OptimizationResult: Sendable {
    case success(OptimizerResult)
    case noEventsToOptimize
    case infeasible(reason: String, snapshot: ScheduleSnapshot? = nil, resolutions: [ActionableResolution] = [])
    case partialSuccess(OptimizerResult, warnings: [String], resolutions: [ActionableResolution] = [])

    var errorMessage: String? {
        switch self {
        case .noEventsToOptimize: return "No events to optimize"
        case .infeasible(let reason, _, _): return reason
        case .partialSuccess(_, let warnings, _): return warnings.first
        case .success: return nil
        }
    }

    var optimizerResult: OptimizerResult? {
        switch self {
        case .success(let r): return r
        case .partialSuccess(let r, _, _): return r
        default: return nil
        }
    }
}

// MARK: - Applied Snapshot (for Undo)

struct AppliedSnapshot: Codable, Sendable {
    let requestName: String
    let appliedAt: Date
    let previousGenes: [ScheduleGene]
    let appliedGenes: [ScheduleGene]
    let createdEventIds: [String]
}

// MARK: - Applied Request Summary (for the Reasoning Surface)

/// Lightweight «what was just applied» record kept on `OptimizerService`
/// for the few seconds after a Run completes. The `SmartActions` row
/// reads this to render its trailing «Done · why?» hint, where tap-on-
/// «why?» reveals which intents the applied request carried.
///
/// Separate from `AppliedSnapshot` (which lives only as long as undo is
/// possible and carries gene-level data) — this one is shorter-lived and
/// purely advisory. Birman: «the optimizer is not magic — it's an explicit rule»;
/// surfacing the intents back to the user closes the loop between «I
/// hit Run» and «I see what the machine actually did».
struct AppliedRequestSummary: Sendable {
    let request: OptimizationRequest
    let label: String
    let appliedAt: Date
    /// Number of events the optimizer placed in this run — fed into
    /// the human-readable summary («Moved 4 tasks»). Zero when the
    /// applied scenario was an empty schedule.
    let taskCount: Int
    /// How many scenarios the optimizer returned for this request. The
    /// applied one is at `appliedScenarioIndex`; the rest are
    /// alternatives the user can swap into via the reasoning-row's
    /// `· · ·` cycle indicator. Both default to 1 / 0 when scenarios
    /// aren't relevant for the run.
    let scenarioCount: Int
    let appliedScenarioIndex: Int

    /// Whether this summary is still recent enough to surface in the UI.
    /// 8-second window matches the typical undo-toast lifetime — once
    /// the toast is gone the «why?» hint should be too, so the user
    /// isn't reading about an action they've already moved past.
    var isFresh: Bool {
        Date().timeIntervalSince(appliedAt) < 8
    }

    /// One-line human-readable summary of what just happened. Combines
    /// the optimizer's `label` with the task count when meaningful.
    var headline: String {
        switch taskCount {
        case 0:  return label
        case 1:  return "\(label) · 1 task"
        default: return "\(label) · \(taskCount) tasks"
        }
    }
}

// MARK: - Energy Adjustment

/// Adjust energy cost based on story points.
/// Higher SP → higher cognitive load → schedule at peak energy.
func adjustedEnergy(base: Double, storyPoints: Int?) -> Double {
    guard let sp = storyPoints, sp > 0 else { return base }
    let normalized = min(1.0, log(Double(sp)) / log(13.0))
    let spEnergy = 0.3 + normalized * 0.65
    return min(1.0, spEnergy * 0.6 + base * 0.4)
}
