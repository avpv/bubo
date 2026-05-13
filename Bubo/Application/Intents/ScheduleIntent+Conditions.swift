import Foundation
import BuboDomain
import BuboOptimizer

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

