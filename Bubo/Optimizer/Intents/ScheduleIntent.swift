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

    // MARK: - Sources (where data comes from)

    /// Only include events from a specific calendar.
    case fromCalendar(name: String)

    /// Only include events/tasks from a specific project.
    case fromProject(name: String)

    /// Restrict to a specific date range.
    case fromTimeRange(start: Date, end: Date)

    // MARK: - Transforms (modify events before GA)

    /// Split tasks longer than N minutes into parts.
    case splitLong(maxMinutes: Int)

    /// Add buffer time between all events.
    case addBuffer(minutes: Int)

    /// Cap total scheduled work time per day.
    case capTotal(minutesPerDay: Int)

    /// Merge adjacent events from the same project into one block.
    case mergeAdjacent(context: String)

    // MARK: - Conditions (runtime branching)

    /// Conditional: if condition met, apply `then` intents; otherwise `else`.
    case when(IntentCondition, then: [ScheduleIntent], otherwise: [ScheduleIntent])

    // MARK: - Output (what to do with result)

    /// Auto-apply best scenario without showing options.
    case autoApply

    /// Show notification with message after completion.
    case notify(message: String)

    /// Run another optimization request after this one completes.
    case chainThen(OptimizationRequest)

    /// Save the current composed intents as a named preset.
    case saveAsPreset(name: String)

    // MARK: - Triggers (when to run)

    /// Run when an event is deleted.
    case onEventDeleted

    /// Run when a new event is created.
    case onNewEvent

    /// Run daily at a specific hour.
    case daily(hour: Int)

    /// Run weekly on a specific day (1=Sun, 2=Mon, ...).
    case weekly(day: Int)

    /// Run after Apple Calendar sync completes.
    case onCalendarSync
}

// MARK: - Intent Condition

/// Runtime condition for `.when` nodes.
enum IntentCondition: Codable, Hashable, Sendable {
    /// Schedule has N or more meetings today.
    case meetingHeavy(threshold: Int)

    /// Nearest deadline within N days.
    case deadlineWithin(days: Int)

    /// Current time is after this hour.
    case afterHour(Int)

    /// Backlog has N or more pending tasks.
    case pendingTasks(threshold: Int)

    /// Specific day of week (1=Sun, 2=Mon, ...).
    case dayOfWeek(Int)

    /// Free gap longer than N minutes exists.
    case hasFreeGap(minutes: Int)
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
        // Sources
        case .fromCalendar(let n): return "From: \(n)"
        case .fromProject(let n): return "Project: \(n)"
        case .fromTimeRange: return "Custom date range"
        // Transforms
        case .splitLong(let m): return "Split tasks > \(m)m"
        case .addBuffer(let m): return "Buffer \(m)m"
        case .capTotal(let m): return "Max \(m)m/day"
        case .mergeAdjacent(let c): return "Merge \(c)"
        // Conditions
        case .when(let cond, _, _): return "If \(cond.label)"
        // Output
        case .autoApply: return "Auto-apply best"
        case .notify(let m): return "Notify: \(m)"
        case .chainThen(let r): return "Then: \(r.name ?? "optimize")"
        case .saveAsPreset(let n): return "Save as \(n)"
        // Triggers
        case .onEventDeleted: return "On event deleted"
        case .onNewEvent: return "On new event"
        case .daily(let h): return "Daily at \(h):00"
        case .weekly(let d): return "Weekly day \(d)"
        case .onCalendarSync: return "On calendar sync"
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
        case .fromCalendar, .fromProject, .fromTimeRange:
            return .source
        case .splitLong, .addBuffer, .capTotal, .mergeAdjacent:
            return .transform
        case .when:
            return .condition
        case .autoApply, .notify, .chainThen, .saveAsPreset:
            return .output
        case .onEventDeleted, .onNewEvent, .daily, .weekly, .onCalendarSync:
            return .trigger
        }
    }
}

// MARK: - Intent Condition Labels

extension IntentCondition {
    var label: String {
        switch self {
        case .meetingHeavy(let n): return "\(n)+ meetings"
        case .deadlineWithin(let d): return "deadline in \(d)d"
        case .afterHour(let h): return "after \(h):00"
        case .pendingTasks(let n): return "\(n)+ pending tasks"
        case .dayOfWeek(let d):
            let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return d < names.count ? names[d] : "day \(d)"
        case .hasFreeGap(let m): return "\(m)m+ free"
        }
    }
}

// MARK: - Intent Category

enum IntentCategory: String, CaseIterable, Sendable {
    case trigger = "Trigger"
    case source = "Source"
    case time = "Time"
    case tasks = "Tasks"
    case create = "Create"
    case transform = "Transform"
    case weights = "Priorities"
    case energy = "Energy"
    case rules = "Rules"
    case condition = "Condition"
    case meta = "Config"
    case output = "Output"
    case rules = "Rules"
    case tasks = "Tasks"
    case meta = "Options"
}

// MARK: - Optimization Request

/// A composable set of intents that fully describes an optimization run.
/// This replaces ScheduleRecipe — instead of a monolithic 10-dimensional config,
/// it's a flat list of composable building blocks.
struct OptimizationRequest: Codable, Hashable, Sendable, Identifiable {
    var intents: [ScheduleIntent]
    var name: String?
    var description: String?
    /// Variable bindings for parameterized subgraphs.
    var variables: [String: PipelineValue] = [:]

    var id: String { name ?? UUID().uuidString }

    init(_ intents: [ScheduleIntent] = [], name: String? = nil, description: String? = nil) {
        self.intents = intents
        self.name = name
        self.description = description
    }

    init(_ intents: ScheduleIntent..., name: String? = nil, description: String? = nil) {
        self.intents = intents
        self.name = name
        self.description = description
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

    /// Whether this is a "find slot" request (existing events stay fixed).
    var findSlotOnly: Bool {
        intents.contains { intent in
            if case .findSlotsForBacklog = intent { return true }
            return false
        }
    }

    /// Category color index for the accent dot in the palette.
    var categoryColorIndex: Int {
        if isCreative { return 0 }  // focus = blue
        if intents.contains(where: {
            if case .prioritizeDeadlines = $0 { return true }
            return false
        }) { return 2 }  // deadlines = red
        return 1  // planning = default
    }

    // MARK: - Search

    func matchesSearch(_ query: String) -> Bool {
        let q = query.lowercased()
        if name?.lowercased().contains(q) == true { return true }
        if description?.lowercased().contains(q) == true { return true }
        return intents.contains { $0.label.lowercased().contains(q) }
    }

    // MARK: - Schedule Preview (heuristic, no GA)

    func schedulePreview(reminderService: ReminderService, workingHours: ClosedRange<Int>) -> String? {
        guard isCreative || findSlotOnly else { return nil }
        // Simple heuristic: show what the request will do
        var parts: [String] = []
        for intent in intents {
            switch intent {
            case .focusBlock(let m, let p):
                let period = p?.rawValue ?? "today"
                parts.append("Focus \(m)m \(period)")
            case .createBlock(let t, let m, _, _):
                parts.append("\(t) \(m)m")
            case .pomodoroSession(let p):
                parts.append("Pomodoro (\(p.rawValue))")
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Compatibility (for CommandPalette)

    /// No recipe params — intents are configured directly.
    var params: [Any] { [] }

    /// No required runtime input for presets.
    var hasRequiredRuntimeInput: Bool { false }

    /// No-op: intents don't use param values.
    mutating func applyParamValues(_ values: [String: Any]) {}

    /// Add event context (e.g. from seed event).
    func withEventContext(_ event: CalendarEvent) -> OptimizationRequest {
        var copy = self
        copy.add(.onlyOptimize(eventIds: [event.id]))
        return copy
    }

    /// Speed intent accessor.
    var speed: Speed {
        get {
            for intent in intents {
                if case .speed(let s) = intent { return s }
            }
            return .quick
        }
        set {
            intents.removeAll { if case .speed = $0 { return true }; return false }
            intents.append(.speed(newValue))
        }
    }

    /// Max scenarios accessor.
    var maxScenarios: Int {
        get {
            for intent in intents {
                if case .scenarios(let n) = intent { return n }
            }
            return 3
        }
        set {
            intents.removeAll { if case .scenarios = $0 { return true }; return false }
            intents.append(.scenarios(count: newValue))
        }
    }

    // MARK: - Intent Composer

    /// Remove an intent at index.
    mutating func removeIntent(at index: Int) {
        guard index < intents.count else { return }
        intents.remove(at: index)
    }

    /// Toggle an intent: add if missing, remove if present.
    mutating func toggle(_ intent: ScheduleIntent) {
        if let idx = intents.firstIndex(of: intent) {
            intents.remove(at: idx)
        } else {
            intents.append(intent)
        }
    }

    /// Available intents that can be added (not already present).
    /// Uses IntentGraph.allKnownIntents as the palette.
    var availableIntents: [ScheduleIntent] {
        IntentGraph.allKnownIntents.filter { candidate in
            !intents.contains(candidate)
        }
    }
}
