import Foundation

// MARK: - Schedule Recipe

/// A fully data-driven optimization recipe.
/// Each recipe is a point in 10-dimensional configuration space.
/// New recipes are created by declaring new static values — zero code changes.
///
/// Dimensions:
///  1. events           — synthetic events to create
///  2. includeExisting   — whether to include existing local events
///  3. horizon           — time range to optimize
///  4. weights           — objective weight overrides
///  5. stability         — how much change from current schedule is ok
///  6. speed             — GA configuration preset
///  7. eventRules        — rules to modify existing events
///  8. conditions        — when this recipe is contextually relevant
///  9. dayStructure      — time block pattern for the day
/// 10. trigger/display   — execution trigger and result presentation
struct ScheduleRecipe: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString

    // MARK: - Display

    var name: String = ""
    var description: String = ""
    var category: String = ""

    // MARK: - 1. Events to Create

    var events: [EventSpec] = []

    // MARK: - 2. Include Existing Local Events

    var includeExistingEvents: Bool = true

    // MARK: - 3. Time Range

    var horizon: Horizon = .today

    // MARK: - 4. Weight Overrides

    var weights: [WeightKey: Double] = [:]

    // MARK: - 5. Stability

    var stability: Stability = .normal

    // MARK: - 6. Speed

    var speed: Speed = .quick

    // MARK: - 7. Event Rules

    var eventRules: [EventRule] = []

    // MARK: - 8. Conditions

    var conditions: [RecipeCondition] = []

    // MARK: - 9. Day Structure

    var dayStructure: [TimeBlock] = []

    // MARK: - 10. Trigger & Behavior

    var trigger: Trigger = .manual
    var display: ResultDisplay = .scenarios
    var postActions: [PostAction] = []

    // MARK: - User Input

    var params: [RecipeParam] = []

    // MARK: - Scenario Control

    var maxScenarios: Int = 3
    var diversityThreshold: Double = 0.15

    // MARK: - Learning

    /// When true, accept/reject feedback is recorded for preference learning.
    var learnable: Bool = true

    // MARK: - Event Selection

    /// When set, only these local event IDs are included in optimization.
    /// nil = include all local events (default behavior).
    var selectedEventIds: [String]? = nil

    // MARK: - Simple Overrides

    var workingHours: HourRange? = nil
    var maxMeetingsPerDay: Int? = nil
    var minBreakMinutes: Int? = nil
    var peakEnergyHour: Int? = nil

    // MARK: - Codable

    /// Custom decoder that tolerates missing keys by falling back to defaults.
    /// This is essential for LLM-generated JSON which only includes a subset of fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        events = (try? c.decode([EventSpec].self, forKey: .events)) ?? []
        includeExistingEvents = (try? c.decode(Bool.self, forKey: .includeExistingEvents)) ?? true
        horizon = (try? c.decode(Horizon.self, forKey: .horizon)) ?? .today
        weights = (try? c.decode([WeightKey: Double].self, forKey: .weights)) ?? [:]
        stability = (try? c.decode(Stability.self, forKey: .stability)) ?? .normal
        speed = (try? c.decode(Speed.self, forKey: .speed)) ?? .quick
        eventRules = (try? c.decode([EventRule].self, forKey: .eventRules)) ?? []
        conditions = (try? c.decode([RecipeCondition].self, forKey: .conditions)) ?? []
        dayStructure = (try? c.decode([TimeBlock].self, forKey: .dayStructure)) ?? []
        trigger = (try? c.decode(Trigger.self, forKey: .trigger)) ?? .manual
        display = (try? c.decode(ResultDisplay.self, forKey: .display)) ?? .scenarios
        postActions = (try? c.decode([PostAction].self, forKey: .postActions)) ?? []
        params = (try? c.decode([RecipeParam].self, forKey: .params)) ?? []
        maxScenarios = (try? c.decode(Int.self, forKey: .maxScenarios)) ?? 3
        diversityThreshold = (try? c.decode(Double.self, forKey: .diversityThreshold)) ?? 0.15
        learnable = (try? c.decode(Bool.self, forKey: .learnable)) ?? true
        selectedEventIds = try? c.decode([String].self, forKey: .selectedEventIds)
        workingHours = try? c.decode(HourRange.self, forKey: .workingHours)
        maxMeetingsPerDay = try? c.decode(Int.self, forKey: .maxMeetingsPerDay)
        minBreakMinutes = try? c.decode(Int.self, forKey: .minBreakMinutes)
        peakEnergyHour = try? c.decode(Int.self, forKey: .peakEnergyHour)
    }

    /// Memberwise initializer (preserves default construction).
    init(
        id: String = UUID().uuidString,
        name: String = "",
        description: String = "",
        category: String = "",
        events: [EventSpec] = [],
        includeExistingEvents: Bool = true,
        horizon: Horizon = .today,
        weights: [WeightKey: Double] = [:],
        stability: Stability = .normal,
        speed: Speed = .quick,
        eventRules: [EventRule] = [],
        conditions: [RecipeCondition] = [],
        dayStructure: [TimeBlock] = [],
        trigger: Trigger = .manual,
        display: ResultDisplay = .scenarios,
        postActions: [PostAction] = [],
        params: [RecipeParam] = [],
        maxScenarios: Int = 3,
        diversityThreshold: Double = 0.15,
        learnable: Bool = true,
        selectedEventIds: [String]? = nil,
        workingHours: HourRange? = nil,
        maxMeetingsPerDay: Int? = nil,
        minBreakMinutes: Int? = nil,
        peakEnergyHour: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.events = events
        self.includeExistingEvents = includeExistingEvents
        self.horizon = horizon
        self.weights = weights
        self.stability = stability
        self.speed = speed
        self.eventRules = eventRules
        self.conditions = conditions
        self.dayStructure = dayStructure
        self.trigger = trigger
        self.display = display
        self.postActions = postActions
        self.params = params
        self.maxScenarios = maxScenarios
        self.diversityThreshold = diversityThreshold
        self.learnable = learnable
        self.selectedEventIds = selectedEventIds
        self.workingHours = workingHours
        self.maxMeetingsPerDay = maxMeetingsPerDay
        self.minBreakMinutes = minBreakMinutes
        self.peakEnergyHour = peakEnergyHour
    }
}

// MARK: - Event Spec

/// Specification for creating synthetic events at execution time.
struct EventSpec: Codable, Hashable {
    var title: String = "Event"
    var minutes: Int = 60
    var count: Int = 1
    var priority: Double = 0.5
    var energy: Double = 0.5
    var context: String? = nil
    var period: Period? = nil
    var focus: Bool = false
    var pomodoro: PomodoroPreset? = nil
    var participants: [String] = []

    /// How to create events at execution time.
    var creation: CreationMode = .fixed

    /// When set, this event is chained to the previous event in the array.
    /// The value is the gap in minutes between the end of the previous event
    /// and the start of this one. nil = independent (optimized separately),
    /// 0 = immediately after, 5 = 5 min gap after previous.
    /// Only the FIRST event in a chain is optimized by the GA;
    /// subsequent chained events are placed sequentially.
    var chainGap: Int? = nil

    /// Sub-segments within this event (e.g., exercises in a circuit).
    /// Rendered as a visual timeline in the UI but scheduled as a single
    /// calendar event. Replaces PomodoroConfig for arbitrary structures.
    var segments: [EventSegment]? = nil

    /// Custom decoder that tolerates missing keys by falling back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Event"
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 60
        count = (try? c.decode(Int.self, forKey: .count)) ?? 1
        priority = (try? c.decode(Double.self, forKey: .priority)) ?? 0.5
        energy = (try? c.decode(Double.self, forKey: .energy)) ?? 0.5
        context = try? c.decode(String.self, forKey: .context)
        period = try? c.decode(Period.self, forKey: .period)
        focus = (try? c.decode(Bool.self, forKey: .focus)) ?? false
        pomodoro = try? c.decode(PomodoroPreset.self, forKey: .pomodoro)
        participants = (try? c.decode([String].self, forKey: .participants)) ?? []
        creation = (try? c.decode(CreationMode.self, forKey: .creation)) ?? .fixed
        chainGap = try? c.decode(Int.self, forKey: .chainGap)
        segments = try? c.decode([EventSegment].self, forKey: .segments)
    }

    init(
        title: String = "Event",
        minutes: Int = 60,
        count: Int = 1,
        priority: Double = 0.5,
        energy: Double = 0.5,
        context: String? = nil,
        period: Period? = nil,
        focus: Bool = false,
        pomodoro: PomodoroPreset? = nil,
        participants: [String] = [],
        creation: CreationMode = .fixed,
        chainGap: Int? = nil,
        segments: [EventSegment]? = nil
    ) {
        self.title = title
        self.minutes = minutes
        self.count = count
        self.priority = priority
        self.energy = energy
        self.context = context
        self.period = period
        self.focus = focus
        self.pomodoro = pomodoro
        self.participants = participants
        self.creation = creation
        self.chainGap = chainGap
        self.segments = segments
    }
}

// MARK: - Event Segment

/// A sub-segment within an event (e.g., one exercise in a circuit).
struct EventSegment: Codable, Hashable {
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

/// The type of segment within an event timeline.
enum SegmentType: String, Codable, Hashable, CaseIterable {
    case work
    case rest
    case transition
}

// MARK: - Creation Mode

/// Determines how the executor creates events from a spec.
enum CreationMode: Codable, Hashable {
    /// Create exactly as specified in the spec.
    case fixed
    /// Auto-detect free gaps and create one event per gap, sized to fit.
    case fillGaps
    /// Find unfinished events from previous days.
    case fromUnfinished
    /// Split an existing event into `count` parts.
    /// String is the event ID (may contain a $placeholder).
    case splitEvent(String)
}

// MARK: - Event Rule

/// A rule that modifies existing events before optimization.
/// Rules are applied in order; later rules override earlier ones
/// when they match the same event and modify the same property.
struct EventRule: Codable, Hashable {
    var match: EventMatch
    var action: EventAction
}

// MARK: - Event Match

/// Selects which existing events a rule applies to.
enum EventMatch: Codable, Hashable {
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

// MARK: - Event Action

/// What to do with matched events.
enum EventAction: Codable, Hashable {
    case setPriority(Double)
    case setPreferredPeriod(Period)
    case markFixed
    case exclude
    case setEnergy(Double)
    case restrictToDays([Int])
}

// MARK: - Recipe Condition

/// When to suggest this recipe to the user.
/// All conditions must be met for the recipe to appear in suggestions.
/// Empty conditions = always available.
enum RecipeCondition: Codable, Hashable {
    case minEvents(Int)
    case maxEvents(Int)
    case hasFocusBlocks
    case noFocusBlocks
    case hasDeadlineWithin(days: Int)
    case meetingHeavy(threshold: Int)
    case dayOfWeek(Int)
    case hasGapLongerThan(minutes: Int)
    case afterHour(Int)
    case hasContext(String)
}

// MARK: - Recipe Parameter

/// A user-configurable parameter shown before recipe execution.
/// Empty params = recipe executes immediately (1-click).
struct RecipeParam: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var kind: ParamKind
    var target: ParamTarget
}

/// The type of UI control to render for a parameter.
enum ParamKind: Codable, Hashable {
    case segmented([Int])
    case stepper(min: Int, max: Int)
    case text
    case eventPicker
    case eventMultiPicker
    case hourPicker(ClosedRange<Int>)
}

/// Where to apply the parameter value in the recipe.
enum ParamTarget: Codable, Hashable {
    case eventMinutes(index: Int)
    case eventCount(index: Int)
    case eventTitle(index: Int)
    case eventContext(index: Int)
    case workingHoursStart
    case workingHoursEnd
    case maxMeetings
    case peakEnergy
    case selectedEventIds
    case placeholder(String)
}

// MARK: - Time Block

/// A block of time in the day structure template.
struct TimeBlock: Codable, Hashable {
    var period: Period
    var allowedTypes: Set<BlockType>
}

/// The type of activity allowed in a time block.
enum BlockType: String, Codable, Hashable, CaseIterable {
    case focus
    case meetings
    case tasks
    case breaks
    case free
}

// MARK: - Post Action

/// An action to perform after optimization completes.
enum PostAction: Codable, Hashable {
    case showScenarios
    case applyBest
    case toast(String)
    case suggestInGap
    case removeOriginalEvent(String)
    case undoable
}

// MARK: - Supporting Enums

enum Horizon: String, Codable, Hashable, CaseIterable {
    case today
    case tomorrow
    case week
}

enum Speed: String, Codable, Hashable, CaseIterable {
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

enum Stability: String, Codable, Hashable, CaseIterable {
    case full
    case normal
    case conservative
}

enum Period: String, Codable, Hashable, CaseIterable {
    case morning
    case afternoon
    case evening

    var hourRange: ClosedRange<Int> {
        switch self {
        case .morning: return 7...12
        case .afternoon: return 12...17
        case .evening: return 17...21
        }
    }
}

enum PomodoroPreset: String, Codable, Hashable, CaseIterable {
    case classic
    case deepWork

    var config: PomodoroConfig {
        switch self {
        case .classic: return .classic
        case .deepWork: return .deepWork
        }
    }

    var totalMinutes: Int {
        switch self {
        case .classic: return 130
        case .deepWork: return 130
        }
    }
}

enum Trigger: Codable, Hashable {
    case manual
    case eventDeleted
    case eventMoved
    case eventCreated
    case periodic(minutes: Int)
}

enum ResultDisplay: String, Codable, Hashable, CaseIterable {
    case scenarios
    case confirmation
    case toast
    case inline
    case dryRun
}

enum WeightKey: String, Codable, Hashable, CaseIterable {
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

/// A start/end hour range (Codable replacement for tuple).
struct HourRange: Codable, Hashable {
    var start: Int
    var end: Int

    var closedRange: ClosedRange<Int> { start...end }
}

// MARK: - Recipe Result

enum RecipeResult: Sendable {
    case success(OptimizerResult)
    case noEventsToOptimize
    case infeasible(reason: String)
    case partialSuccess(OptimizerResult, warnings: [String])

    var errorMessage: String? {
        switch self {
        case .noEventsToOptimize: return "No events to optimize"
        case .infeasible(let reason): return reason
        case .partialSuccess(_, let warnings): return warnings.first
        case .success: return nil
        }
    }

    var optimizerResult: OptimizerResult? {
        switch self {
        case .success(let r): return r
        case .partialSuccess(let r, _): return r
        default: return nil
        }
    }
}

// MARK: - Recipe Classification

extension ScheduleRecipe {
    /// Whether this recipe creates new event blocks (focus, pomodoro, workout, etc.)
    /// vs rearranging existing ones.
    var isCreative: Bool {
        !events.isEmpty
    }

    /// Whether this recipe requires existing local events to work.
    /// Planning/organizing recipes need tasks to rearrange.
    var needsExistingEvents: Bool {
        events.isEmpty && includeExistingEvents
    }

    /// Human-readable verb for the primary action button.
    var actionLabel: String {
        if isCreative { return "Find Best Time" }
        return "Optimize"
    }
}

// MARK: - Applied Recipe Snapshot (for Undo)

struct AppliedRecipeSnapshot: Codable {
    let recipeId: String
    let appliedAt: Date
    let previousGenes: [ScheduleGene]
    let appliedGenes: [ScheduleGene]
    let createdEventIds: [String]
}

// MARK: - Param Application

extension ScheduleRecipe {

    /// Apply user-provided parameter values to this recipe (mutating).
    mutating func applyParamValues(_ values: [String: Any]) {
        for param in params {
            guard let value = values[param.id] else { continue }
            switch param.target {
            case .eventMinutes(let index):
                guard index < events.count, let v = value as? Int else { continue }
                events[index].minutes = v
            case .eventCount(let index):
                guard index < events.count, let v = value as? Int else { continue }
                events[index].count = v
            case .eventTitle(let index):
                guard index < events.count, let v = value as? String else { continue }
                events[index].title = v
            case .eventContext(let index):
                guard index < events.count, let v = value as? String else { continue }
                events[index].context = v
            case .workingHoursStart:
                guard let v = value as? Int else { continue }
                let end = workingHours?.end ?? 18
                workingHours = HourRange(start: v, end: end)
            case .workingHoursEnd:
                guard let v = value as? Int else { continue }
                let start = workingHours?.start ?? 9
                workingHours = HourRange(start: start, end: v)
            case .maxMeetings:
                guard let v = value as? Int else { continue }
                maxMeetingsPerDay = v
            case .peakEnergy:
                guard let v = value as? Int else { continue }
                peakEnergyHour = v
            case .selectedEventIds:
                if let ids = value as? [String] {
                    selectedEventIds = ids
                }
            case .placeholder(let name):
                replacePlaceholder(name, with: "\(value)")
            }
        }
    }

    /// Replace $placeholder in events and eventRules.
    private mutating func replacePlaceholder(_ name: String, with value: String) {
        let token = "$\(name)"

        // Replace in events
        for i in events.indices {
            if events[i].title.contains(token) {
                events[i].title = events[i].title.replacingOccurrences(of: token, with: value)
            }
            if events[i].context?.contains(token) == true {
                events[i].context = events[i].context?.replacingOccurrences(of: token, with: value)
            }
            if case .splitEvent(let id) = events[i].creation, id.contains(token) {
                events[i].creation = .splitEvent(id.replacingOccurrences(of: token, with: value))
            }
        }

        // Replace in event rules
        for i in eventRules.indices {
            if case .context(let ctx) = eventRules[i].match, ctx.contains(token) {
                eventRules[i].match = .context(ctx.replacingOccurrences(of: token, with: value))
            }
            if case .id(let id) = eventRules[i].match, id.contains(token) {
                eventRules[i].match = .id(id.replacingOccurrences(of: token, with: value))
            }
        }

        // Replace in post actions
        for i in postActions.indices {
            if case .removeOriginalEvent(let id) = postActions[i], id.contains(token) {
                postActions[i] = .removeOriginalEvent(id.replacingOccurrences(of: token, with: value))
            }
        }
    }
}
