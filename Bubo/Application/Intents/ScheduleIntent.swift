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

