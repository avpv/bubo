import Foundation
import BuboDomain
import BuboOptimizer

// MARK: - Schedule Intent

/// A composable building block for schedule optimization.
/// Replaces the monolithic ScheduleRecipe with atomic, mixable intents.
///
/// Intents compose naturally: [.focusMorning, .lateStart(11), .prioritizeDeadlines]
/// Each intent is a micro-transformation on the optimization request.
/// Named presets are just arrays of intents.
indirect enum ScheduleIntent: Codable, Hashable, Sendable {

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

    /// Create a pomodoro session. The optimizer derives work / break /
    /// rounds / longBreak from live signals (available slot, task estimate,
    /// energy curve, deadline) — no preset to pick.
    case pomodoroSession

    /// Pack several small related backlog tasks into a single pomodoro
    /// session — one task per work round. `maxTasks` caps the pack size;
    /// `contextFilter` optionally restricts to tasks sharing a project /
    /// context tag. When the burst consumes fewer than 2 tasks the
    /// compiler falls through to the regular `.pomodoroSession`
    /// behaviour, so picking this intent with a sparse backlog is safe.
    case focusBurst(maxTasks: Int = 4, contextFilter: String? = nil)

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

    /// Limit the number of scheduled backlog tasks to the top N (drops everything else).
    case limitToTopTasks(count: Int)

    /// Schedule backlog tasks, treating existing events as fixed obstacles.
    case findSlotsForBacklog

    // MARK: - Speed

    /// GA preset: quick / balanced / thorough.
    case speed(Speed)

    // MARK: - Display

    /// How many scenarios to show (1 = auto-apply best).
    case scenarios(count: Int)

    // MARK: - Smart Scheduling

    /// Reserve % of day for unplanned work (contingency buffer).
    case contingencyBuffer(percent: Int)

    /// No meetings within N minutes of focus blocks.
    case focusProtection(bufferMinutes: Int)

    /// Auto-add prep time before meetings.
    case meetingPrep(minutes: Int)

    /// Wind down: lighter tasks toward end of day.
    case windDown(lastHours: Int)

    /// Task ordering strategy.
    case taskOrder(TaskOrderStrategy)

    /// Minimum gap between any two events (no back-to-back).
    case minGap(minutes: Int)

    /// Flexible duration: task can shrink/expand within a range. GA decides.
    case flexDuration(minMinutes: Int, maxMinutes: Int)

    /// Repeat yesterday's schedule structure.
    case likeYesterday

    /// Half day — only morning or afternoon.
    case halfDay(HalfDayMode)

    /// Warm-up: schedule an easy task before a hard one.
    case warmUp(minutes: Int)

    /// Cool-down: schedule an easy task after a hard one.
    case coolDown(minutes: Int)

    /// Commute/travel buffer between events at different locations.
    case travelBuffer(minutes: Int)

    /// Reserve end-of-day review block.
    case endOfDayReview(minutes: Int)

    /// Match energy curve: high-energy tasks at peak, low-energy at trough.
    case matchEnergyCurve

    /// Time-box: enforce strict maximum duration per task.
    case timeBox(maxMinutes: Int)

    // MARK: - Social / Team

    /// Sync with a colleague's availability.
    case syncWith(person: String)

    /// Open "office hours" slot for ad-hoc questions.
    case officeHours(start: Int, end: Int)

    /// Schedule pair work — find a shared free slot.
    case pairWork(person: String, minutes: Int)

    /// No overlapping events across multiple calendars.
    case noOverlap

    // MARK: - Health / Habits

    /// Micro-break every N minutes (water, stretch).
    case microBreak(everyMinutes: Int, durationMinutes: Int)

    /// Walk break after N minutes of sitting.
    case walkBreak(afterMinutes: Int, durationMinutes: Int)

    /// Pin an event at exact time (like lunch at 13:00).
    case pinAt(title: String, hour: Int, minutes: Int)

    /// No screens after this hour (digital sunset).
    case noScreensAfter(hour: Int)

    // MARK: - Context / Batching

    /// Batch events by tool (all Zoom together, all Figma together).
    case batchByTool(tool: String)

    /// Deep/shallow split: deep work in one period, shallow in another.
    case deepShallowSplit(deepPeriod: Period, shallowPeriod: Period)

    /// Group events at the same location together.
    case groupByLocation

    /// Guarantee N consecutive hours on one project.
    case uninterruptedBlock(project: String, hours: Int)

    // MARK: - Adaptive

    /// If main tasks fit, add stretch goals from backlog.
    case stretchGoals(maxExtra: Int)

    /// Explicitly overflow unfinished tasks to tomorrow.
    case overflowToTomorrow

    /// Mid-day energy check-in: re-evaluate and suggest adjustments.
    case energyCheckIn(atHour: Int)

    // MARK: - Temporal Scope

    /// This intent applies only today (not saved to pipeline).
    case todayOnly(ScheduleIntent)

    /// This intent applies until a specific date.
    case until(Date, ScheduleIntent)

    /// Skip weekends in planning horizon.
    case skipWeekends

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

/// Task ordering strategy for the optimizer.
enum TaskOrderStrategy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Shortest tasks first (quick wins).
    case shortestFirst
    /// Longest/hardest tasks first (eat the frog).
    case hardestFirst
    /// Deadline-nearest first.
    case urgentFirst
    /// Highest priority first.
    case priorityFirst
    /// Alternate between hard and easy.
    case alternating

    var label: String {
        switch self {
        case .shortestFirst: return "Shortest first"
        case .hardestFirst: return "Hardest first"
        case .urgentFirst: return "Urgent first"
        case .priorityFirst: return "Priority first"
        case .alternating: return "Alternate hard/easy"
        }
    }
}

/// Half-day mode.
enum HalfDayMode: String, Codable, Hashable, Sendable, CaseIterable {
    case morningOnly
    case afternoonOnly
}

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
            return "Focus \(m)\u{00A0}min\(period)"
        case .createBlock(let t, let m, _, _): return "\(t) (\(m)\u{00A0}min)"
        case .pomodoroSession: return "Pomodoro"
        case .focusBurst(let n, let ctx):
            if let ctx { return "Focus burst · \(ctx) · \(n)\u{00A0}tasks" }
            return "Focus burst · \(n)\u{00A0}tasks"
        case .prioritizeDeadlines: return "Prioritize deadlines"
        case .prioritizeFocus: return "Prioritize focus time"
        case .minimizeContextSwitching: return "Minimize context switching"
        case .groupByProject: return "Group by project"
        case .batchMeetings: return "Batch meetings"
        case .lowEnergy: return "Low energy mode"
        case .peakEnergy(let h): return "Peak energy at \(h):00"
        case .morningPerson: return "Morning-heavy schedule"
        case .protectLunch: return "Protect lunch"
        case .breakEvery(let w, let b): return "Break \(b)\u{00A0}min every \(w)\u{00A0}min"
        case .maxMeetings(let n): return "Max \(n)\u{00A0}meetings/day"
        case .stability(let s): return "Stability: \(s.rawValue)"
        case .keepFixed: return "Keep events fixed"
        case .exclude: return "Exclude events"
        case .onlyOptimize: return "Only optimize selected"
        case .preferPeriod(_, let p): return "Prefer \(p.rawValue)"
        case .includeBacklog: return "Include backlog tasks"
        case .includeBacklogTasks(let ids): return "Limit to \(ids.count)\u{00A0}specific tasks"
        case .limitToTopTasks(let c): return "Only top \(c)\u{00A0}tasks"
        case .findSlotsForBacklog: return "Fill free slots for tasks"
        case .speed(let s): return "Speed: \(s.rawValue)"
        case .scenarios(let n): return n == 1 ? "Auto-apply" : "\(n)\u{00A0}scenarios"
        // Smart scheduling
        case .contingencyBuffer(let p): return "Reserve \(p)% for unplanned"
        case .focusProtection(let m): return "Protect focus ±\(m)\u{00A0}min"
        case .meetingPrep(let m): return "Prep \(m)\u{00A0}min before meetings"
        case .windDown(let h): return "Wind down last \(h)\u{00A0}h"
        case .taskOrder(let s): return s.label
        case .minGap(let m): return "Min \(m)\u{00A0}min between events"
        case .flexDuration(let min, let max): return "Flex \(min)–\(max)\u{00A0}min"
        case .likeYesterday: return "Like yesterday"
        case .halfDay(let m): return m == .morningOnly ? "Morning only" : "Afternoon only"
        case .warmUp(let m): return "Warm-up \(m)\u{00A0}min"
        case .coolDown(let m): return "Cool-down \(m)\u{00A0}min"
        case .travelBuffer(let m): return "Travel buffer \(m)\u{00A0}min"
        case .endOfDayReview(let m): return "EOD review \(m)\u{00A0}min"
        case .matchEnergyCurve: return "Match energy curve"
        case .timeBox(let m): return "Time-box \(m)\u{00A0}min max"
        // Social
        case .syncWith(let p): return "Sync with \(p)"
        case .officeHours(let s, let e): return "Office hours \(s)–\(e)"
        case .pairWork(let p, let m): return "Pair with \(p) \(m)\u{00A0}min"
        case .noOverlap: return "No overlapping events"
        // Health
        case .microBreak(let e, let d): return "Break \(d)\u{00A0}min every \(e)\u{00A0}min"
        case .walkBreak(let a, let d): return "Walk \(d)\u{00A0}min after \(a)\u{00A0}min"
        case .pinAt(let t, let h, _): return "\(t) at \(h):00"
        case .noScreensAfter(let h): return "No screens after \(h):00"
        // Context
        case .batchByTool(let t): return "Batch \(t) calls"
        case .deepShallowSplit(let d, let s): return "Deep \(d.rawValue) / shallow \(s.rawValue)"
        case .groupByLocation: return "Group by location"
        case .uninterruptedBlock(let p, let h): return "\(p) \(h)\u{00A0}h uninterrupted"
        // Adaptive
        case .stretchGoals(let n): return "Stretch +\(n)\u{00A0}tasks"
        case .overflowToTomorrow: return "Overflow → tomorrow"
        case .energyCheckIn(let h): return "Energy check at \(h):00"
        // Temporal
        case .todayOnly(let i): return "\(i.label) (today only)"
        case .until(_, let i): return "\(i.label) (temporary)"
        case .skipWeekends: return "Skip weekends"
        // Sources
        case .fromCalendar(let n): return "From: \(n)"
        case .fromProject(let n): return "Project: \(n)"
        case .fromTimeRange: return "Custom date range"
        // Transforms
        case .splitLong(let m): return "Split tasks > \(m)\u{00A0}min"
        case .addBuffer(let m): return "Buffer \(m)\u{00A0}min"
        case .capTotal(let m): return "Max \(m)\u{00A0}min/day"
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
        case .focusBlock, .createBlock, .pomodoroSession, .focusBurst:
            return .create
        case .prioritizeDeadlines, .prioritizeFocus, .minimizeContextSwitching,
             .groupByProject, .batchMeetings:
            return .weights
        case .lowEnergy, .peakEnergy, .morningPerson, .protectLunch,
             .breakEvery, .maxMeetings:
            return .energy
        case .stability, .keepFixed, .exclude, .onlyOptimize, .preferPeriod:
            return .rules
        case .includeBacklog, .includeBacklogTasks, .limitToTopTasks, .findSlotsForBacklog:
            return .tasks
        case .speed, .scenarios:
            return .meta
        case .contingencyBuffer, .focusProtection, .meetingPrep, .windDown,
             .warmUp, .coolDown, .travelBuffer, .endOfDayReview:
            return .energy
        case .taskOrder, .minGap, .flexDuration, .timeBox:
            return .rules
        case .likeYesterday, .halfDay, .matchEnergyCurve:
            return .energy
        case .syncWith, .officeHours, .pairWork, .noOverlap:
            return .social
        case .microBreak, .walkBreak, .noScreensAfter:
            return .energy
        case .pinAt:
            return .create
        case .batchByTool, .deepShallowSplit, .groupByLocation, .uninterruptedBlock:
            return .rules
        case .stretchGoals, .overflowToTomorrow, .energyCheckIn:
            return .output
        case .todayOnly, .until, .skipWeekends:
            return .time
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
        case .hasFreeGap(let m): return "\(m)\u{00A0}min+ free"
        }
    }
}

// MARK: - Single-Cardinality Categories

/// Intent families where at most one setting makes sense per request.
/// When a request ends up with two `.speed` intents the optimizer can only
/// honour one, so both the conflict detector (to warn the user) and the
/// suggestion composer (to auto-resolve) key off this enum.
///
/// Keep this enum and ``ScheduleIntent/singleCardinalityKey`` in sync when
/// new single-valued intent families are introduced.
enum IntentCardinalityKey: String, Hashable, Sendable, CaseIterable {
    case speed
    case horizon
    case scenarios
    case stability
}

extension ScheduleIntent {
    /// Non-nil when this intent belongs to a single-cardinality family.
    /// Consumers should treat two intents sharing a key as mutually
    /// exclusive and pick one.
    var singleCardinalityKey: IntentCardinalityKey? {
        switch self {
        case .speed: return .speed
        case .horizon: return .horizon
        case .scenarios: return .scenarios
        case .stability: return .stability
        default: return nil
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
    case social = "Social"
    case meta = "Config"
    case output = "Output"
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
            case .focusBlock, .createBlock, .pomodoroSession, .focusBurst: return true
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
                parts.append("Focus \(m)\u{00A0}min \(period)")
            case .createBlock(let t, let m, _, _):
                parts.append("\(t) \(m)\u{00A0}min")
            case .pomodoroSession:
                parts.append("Pomodoro")
            case .focusBurst(let n, _):
                parts.append("Focus burst \(n)")
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

// MARK: - Logging Helpers

extension ScheduleIntent {

    /// Machine-readable case name stripped of associated values.
    /// The prose `label` changes with every numeric parameter, which
    /// makes log aggregation useless. `caseName` returns a stable
    /// identifier (`"noEventsBefore"`, `"focusBlock"`, etc.) that
    /// survives parameter changes and is safe to use as a log key.
    var caseName: String {
        let desc = String(describing: self)
        if let paren = desc.firstIndex(of: "(") {
            return String(desc[..<paren])
        }
        return desc
    }
}
