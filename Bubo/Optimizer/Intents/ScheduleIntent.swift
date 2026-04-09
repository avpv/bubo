import Foundation

// MARK: - Schedule Intent

/// A composable building block for schedule optimization.
/// Replaces the monolithic ScheduleRecipe with atomic, mixable intents.
///
/// Intents compose naturally: [.focusMorning, .lateStart(11), .prioritizeDeadlines]
/// Each intent is a micro-transformation on the optimization request.
/// Named presets are just arrays of intents.
enum ScheduleIntent: Codable, Hashable, Sendable {

    // MARK: - Time Constraints

    /// Block events before this hour.
    case noEventsBefore(hour: Int)

    /// Block events after this hour.
    case noEventsAfter(hour: Int)

    /// Override working hours for this run.
    case workingHours(start: Int, end: Int)

    /// Optimize only today / tomorrow / this week.
    case horizon(Horizon)

    // MARK: - Event Creation

    /// Create a focus block of given duration.
    case focusBlock(minutes: Int, period: Period? = nil)

    /// Create a generic event block.
    case createBlock(title: String, minutes: Int, period: Period? = nil, focus: Bool = false)

    /// Create a pomodoro session.
    case pomodoroSession(preset: PomodoroPreset = .classic)

    // MARK: - Weight Adjustments

    /// Boost deadline importance.
    case prioritizeDeadlines(weight: Double = 2.0)

    /// Boost focus block quality.
    case prioritizeFocus(weight: Double = 2.0)

    /// Reduce context switching.
    case minimizeContextSwitching(weight: Double = 1.5)

    /// Group events by project.
    case groupByProject(weight: Double = 1.5)

    /// Cluster meetings together.
    case batchMeetings(weight: Double = 1.5)

    // MARK: - Energy & Balance

    /// Indicate low energy — prefer shorter tasks, more breaks.
    case lowEnergy

    /// Set peak energy hour.
    case peakEnergy(hour: Int)

    /// Prefer morning-heavy schedule.
    case morningPerson

    /// Protect lunch window.
    case protectLunch(start: Int = 12, end: Int = 14)

    /// Add breaks every N minutes.
    case breakEvery(workMinutes: Int, breakMinutes: Int)

    /// Limit meetings per day.
    case maxMeetings(perDay: Int)

    // MARK: - Stability

    /// How much the optimizer can rearrange existing events.
    case stability(Stability)

    // MARK: - Event Rules

    /// Keep specific events fixed (don't move them).
    case keepFixed(eventIds: [String])

    /// Exclude specific events from optimization.
    case exclude(eventIds: [String])

    /// Only optimize these specific events.
    case onlyOptimize(eventIds: [String])

    /// Set preferred period for matching events.
    case preferPeriod(match: EventMatch, period: Period)

    // MARK: - Task Selection

    /// Include backlog tasks in optimization.
    case includeBacklog

    /// Include only specific backlog task IDs.
    case includeBacklogTasks(ids: [String])

    /// Schedule backlog tasks, treating existing events as fixed obstacles.
    case findSlotsForBacklog

    // MARK: - Speed

    /// GA preset: quick / balanced / thorough.
    case speed(Speed)

    // MARK: - Display

    /// How many scenarios to show (1 = auto-apply best).
    case scenarios(count: Int)
}

// MARK: - Intent Application

extension ScheduleIntent {

    /// Human-readable label for display in command palette.
    var label: String {
        switch self {
        case .noEventsBefore(let h): return "No events before \(h):00"
        case .noEventsAfter(let h): return "No events after \(h):00"
        case .workingHours(let s, let e): return "Working hours \(s):00–\(e):00"
        case .horizon(let h): return h.rawValue.capitalized
        case .focusBlock(let m, let p):
            let period = p.map { ", \($0.rawValue)" } ?? ""
            return "Focus \(m) min\(period)"
        case .createBlock(let t, let m, _, _): return "\(t) (\(m) min)"
        case .pomodoroSession(let p): return "Pomodoro (\(p.rawValue))"
        case .prioritizeDeadlines: return "Prioritize deadlines"
        case .prioritizeFocus: return "Prioritize focus time"
        case .minimizeContextSwitching: return "Minimize context switching"
        case .groupByProject: return "Group by project"
        case .batchMeetings: return "Batch meetings"
        case .lowEnergy: return "Low energy mode"
        case .peakEnergy(let h): return "Peak energy at \(h):00"
        case .morningPerson: return "Morning-heavy schedule"
        case .protectLunch: return "Protect lunch"
        case .breakEvery(let w, let b): return "Break \(b)m every \(w)m"
        case .maxMeetings(let n): return "Max \(n) meetings/day"
        case .stability(let s): return "Stability: \(s.rawValue)"
        case .keepFixed: return "Keep events fixed"
        case .exclude: return "Exclude events"
        case .onlyOptimize: return "Only optimize selected"
        case .preferPeriod(_, let p): return "Prefer \(p.rawValue)"
        case .includeBacklog: return "Include backlog tasks"
        case .includeBacklogTasks: return "Include selected tasks"
        case .findSlotsForBacklog: return "Find slots for tasks"
        case .speed(let s): return "Speed: \(s.rawValue)"
        case .scenarios(let n): return n == 1 ? "Auto-apply" : "\(n) scenarios"
        }
    }

    /// Category for grouping in the command palette.
    var category: IntentCategory {
        switch self {
        case .noEventsBefore, .noEventsAfter, .workingHours, .horizon:
            return .time
        case .focusBlock, .createBlock, .pomodoroSession:
            return .create
        case .prioritizeDeadlines, .prioritizeFocus, .minimizeContextSwitching,
             .groupByProject, .batchMeetings:
            return .weights
        case .lowEnergy, .peakEnergy, .morningPerson, .protectLunch,
             .breakEvery, .maxMeetings:
            return .energy
        case .stability, .keepFixed, .exclude, .onlyOptimize, .preferPeriod:
            return .rules
        case .includeBacklog, .includeBacklogTasks, .findSlotsForBacklog:
            return .tasks
        case .speed, .scenarios:
            return .meta
        }
    }
}

// MARK: - Intent Category

enum IntentCategory: String, CaseIterable, Sendable {
    case time = "Time"
    case create = "Create"
    case weights = "Priorities"
    case energy = "Energy"
    case rules = "Rules"
    case tasks = "Tasks"
    case meta = "Options"
}

// MARK: - Optimization Request

/// A composable set of intents that fully describes an optimization run.
/// This replaces ScheduleRecipe — instead of a monolithic 10-dimensional config,
/// it's a flat list of composable building blocks.
struct OptimizationRequest: Codable, Hashable, Sendable {
    var intents: [ScheduleIntent]
    var name: String?              // nil for ad-hoc requests, set for presets

    init(_ intents: [ScheduleIntent] = [], name: String? = nil) {
        self.intents = intents
        self.name = name
    }

    init(_ intents: ScheduleIntent..., name: String? = nil) {
        self.intents = intents
        self.name = name
    }

    mutating func add(_ intent: ScheduleIntent) {
        intents.append(intent)
    }

    /// Merge another request's intents. Later intents override earlier ones
    /// when they conflict (same category).
    mutating func merge(_ other: OptimizationRequest) {
        intents.append(contentsOf: other.intents)
    }

    /// Whether this request creates new event blocks.
    var isCreative: Bool {
        intents.contains { intent in
            switch intent {
            case .focusBlock, .createBlock, .pomodoroSession: return true
            default: return false
            }
        }
    }
}
