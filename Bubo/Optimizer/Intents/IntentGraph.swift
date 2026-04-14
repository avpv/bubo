import Foundation

// MARK: - Intent Graph

/// A directed acyclic graph of schedule intents.
/// Each node is an intent with typed edges to other nodes.
/// The graph handles dependency resolution, phase ordering,
/// conflict detection, and conditional logic.
///
/// Users never see this — they add/remove chips. The graph
/// auto-resolves dependencies and compiles in the right order.
struct IntentGraph: Sendable {

    // MARK: - Node

    struct Node: Identifiable, Sendable {
        let id: String
        let intent: ScheduleIntent
        let phase: Phase
        /// Whether this node was auto-added to satisfy a dependency.
        var isAutoResolved: Bool = false
        /// Whether this node is conditional (only activates when condition met).
        var condition: Condition? = nil
    }

    /// Typed edge between two nodes.
    struct Edge: Sendable {
        let from: String  // node ID
        let to: String    // node ID
        let kind: EdgeKind
    }

    enum EdgeKind: Sendable {
        /// `from` must be resolved before `to` (ordering).
        case dependsOn
        /// `from` requires `to` to be present (auto-add).
        case requires
        /// `from` and `to` cannot coexist.
        case conflicts
        /// `from` implies `to` (weaker than requires — suggestion, not auto-add).
        case suggests
    }

    /// Execution phases in topological order.
    /// Full pipeline: trigger → source → context → tasks → create → transform → weights → energy → rules → condition → config → output
    enum Phase: Int, Comparable, CaseIterable, Sendable {
        case trigger = 0
        case source = 1
        case context = 2
        case tasks = 3
        case create = 4
        case transform = 5
        case weights = 6
        case energy = 7
        case rules = 8
        case condition = 9
        case config = 10
        case output = 11

        static func < (lhs: Phase, rhs: Phase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Condition for conditional nodes.
    enum Condition: Sendable {
        /// Activate when the schedule has N+ meetings today.
        case meetingHeavy(threshold: Int)
        /// Activate when backlog has N+ pending tasks.
        case pendingTasks(threshold: Int)
        /// Activate at a specific time of day.
        case afterHour(Int)
        /// Activate on specific days of week.
        case dayOfWeek([Int])
        /// Always active (default).
        case always
    }

    // MARK: - State

    private(set) var nodes: [String: Node] = [:]
    private(set) var edges: [Edge] = []

    // MARK: - Build from flat intents

    /// Build a graph from a flat intent list. Auto-resolves dependencies.
    static func build(from intents: [ScheduleIntent]) -> IntentGraph {
        var graph = IntentGraph()

        // Add all explicit intents as nodes
        for intent in intents {
            graph.addNode(intent)
        }

        // Auto-resolve dependencies
        graph.resolveDependencies()

        // Detect and add conflict edges
        graph.detectConflicts()

        return graph
    }

    // MARK: - Add / Remove

    mutating func addNode(_ intent: ScheduleIntent, isAutoResolved: Bool = false, condition: Condition? = nil) {
        let id = nodeId(for: intent)
        guard nodes[id] == nil else { return }  // no duplicates
        nodes[id] = Node(
            id: id,
            intent: intent,
            phase: Self.phase(for: intent),
            isAutoResolved: isAutoResolved,
            condition: condition
        )
    }

    mutating func removeNode(_ intent: ScheduleIntent) {
        let id = nodeId(for: intent)
        nodes.removeValue(forKey: id)
        edges.removeAll { $0.from == id || $0.to == id }

        // Re-check: remove auto-resolved nodes that are no longer needed
        pruneOrphanedAutoNodes()
    }

    mutating func addEdge(from: ScheduleIntent, to: ScheduleIntent, kind: EdgeKind) {
        let edge = Edge(from: nodeId(for: from), to: nodeId(for: to), kind: kind)
        edges.append(edge)
    }

    // MARK: - Dependency Resolution

    /// Auto-add required intents that are missing.
    mutating func resolveDependencies() {
        var changed = true
        while changed {
            changed = false
            let currentNodes = Array(nodes.values)

            for node in currentNodes {
                for dep in Self.dependencies(for: node.intent) {
                    let depId = nodeId(for: dep)
                    if nodes[depId] == nil {
                        addNode(dep, isAutoResolved: true)
                        addEdge(from: node.intent, to: dep, kind: .requires)
                        changed = true
                    }
                }
            }
        }
    }

    /// Remove auto-resolved nodes that no one depends on anymore.
    private mutating func pruneOrphanedAutoNodes() {
        let autoNodes = nodes.values.filter { $0.isAutoResolved }
        for node in autoNodes {
            let hasDependent = edges.contains { $0.to == node.id && $0.kind == .requires }
            if !hasDependent {
                nodes.removeValue(forKey: node.id)
                edges.removeAll { $0.from == node.id || $0.to == node.id }
            }
        }
    }

    // MARK: - Conflict Detection

    mutating func detectConflicts() {
        let nodeList = Array(nodes.values)

        for i in 0..<nodeList.count {
            for j in (i+1)..<nodeList.count {
                if Self.conflictReason(nodeList[i].intent, nodeList[j].intent) != nil {
                    addEdge(from: nodeList[i].intent, to: nodeList[j].intent, kind: .conflicts)
                }
            }
        }
    }

    /// All conflict edges with human-readable reasons.
    var conflicts: [(Node, Node, String)] {
        edges.compactMap { edge in
            guard edge.kind == .conflicts,
                  let from = nodes[edge.from],
                  let to = nodes[edge.to] else { return nil }
            let reason = Self.conflictReason(from.intent, to.intent) ?? "Conflict"
            return (from, to, reason)
        }
    }

    // MARK: - Topological Sort (Compile Order)

    /// Return intents in correct compilation order (by phase, then dependency).
    func sortedIntents() -> [ScheduleIntent] {
        let sorted = nodes.values.sorted { lhs, rhs in
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            // Within same phase, dependencies first
            let lhsDeps = edges.filter { $0.to == lhs.id && $0.kind == .dependsOn }.count
            let rhsDeps = edges.filter { $0.to == rhs.id && $0.kind == .dependsOn }.count
            return lhsDeps < rhsDeps
        }
        return sorted.map(\.intent)
    }

    /// Return intents grouped by phase for display.
    func intentsByPhase() -> [(phase: Phase, intents: [Node])] {
        let grouped = Dictionary(grouping: nodes.values) { $0.phase }
        return Phase.allCases.compactMap { phase in
            guard let nodes = grouped[phase], !nodes.isEmpty else { return nil }
            return (phase: phase, intents: nodes.sorted { $0.id < $1.id })
        }
    }

    /// Suggested intents based on graph structure (suggestions from edges + learner).
    func suggestedIntents() -> [ScheduleIntent] {
        var suggestions: Set<String> = []
        for node in nodes.values {
            for suggestion in Self.suggestions(for: node.intent) {
                let id = nodeId(for: suggestion)
                if nodes[id] == nil {
                    suggestions.insert(id)
                }
            }
        }
        // Also add from 'suggests' edges
        for edge in edges where edge.kind == .suggests {
            if nodes[edge.to] == nil {
                suggestions.insert(edge.to)
            }
        }
        return suggestions.compactMap { id in
            Self.allKnownIntents.first { nodeId(for: $0) == id }
        }
    }

    // MARK: - To Flat List

    /// Export back to a flat list (for OptimizationRequest).
    /// Excludes auto-resolved nodes that users didn't add explicitly —
    /// they'll be re-resolved at compile time.
    func toIntentList(includeAutoResolved: Bool = true) -> [ScheduleIntent] {
        if includeAutoResolved {
            return sortedIntents()
        }
        return nodes.values
            .filter { !$0.isAutoResolved }
            .sorted { $0.phase < $1.phase }
            .map(\.intent)
    }

    // MARK: - Node ID

    private func nodeId(for intent: ScheduleIntent) -> String {
        switch intent {
        case .noEventsBefore: return "noEventsBefore"
        case .noEventsAfter: return "noEventsAfter"
        case .workingHours: return "workingHours"
        case .horizon(let h): return "horizon.\(h.rawValue)"
        case .focusBlock: return "focusBlock"
        case .createBlock(let t, _, _, _): return "createBlock.\(t)"
        case .pomodoroSession: return "pomodoroSession"
        case .prioritizeDeadlines: return "prioritizeDeadlines"
        case .prioritizeFocus: return "prioritizeFocus"
        case .minimizeContextSwitching: return "minimizeContextSwitching"
        case .groupByProject: return "groupByProject"
        case .batchMeetings: return "batchMeetings"
        case .lowEnergy: return "lowEnergy"
        case .peakEnergy: return "peakEnergy"
        case .morningPerson: return "morningPerson"
        case .protectLunch: return "protectLunch"
        case .breakEvery: return "breakEvery"
        case .maxMeetings: return "maxMeetings"
        case .stability(let s): return "stability.\(s.rawValue)"
        case .keepFixed: return "keepFixed"
        case .exclude: return "exclude"
        case .onlyOptimize: return "onlyOptimize"
        case .preferPeriod: return "preferPeriod"
        case .includeBacklog: return "includeBacklog"
        case .includeBacklogTasks: return "includeBacklogTasks"
        case .findSlotsForBacklog: return "findSlotsForBacklog"
        case .speed(let s): return "speed.\(s.rawValue)"
        case .scenarios: return "scenarios"
        // Smart scheduling
        case .contingencyBuffer: return "contingencyBuffer"
        case .focusProtection: return "focusProtection"
        case .meetingPrep: return "meetingPrep"
        case .windDown: return "windDown"
        case .taskOrder(let s): return "taskOrder.\(s.rawValue)"
        case .minGap: return "minGap"
        case .flexDuration: return "flexDuration"
        case .likeYesterday: return "likeYesterday"
        case .halfDay(let m): return "halfDay.\(m.rawValue)"
        case .warmUp: return "warmUp"
        case .coolDown: return "coolDown"
        case .travelBuffer: return "travelBuffer"
        case .endOfDayReview: return "endOfDayReview"
        case .matchEnergyCurve: return "matchEnergyCurve"
        case .timeBox: return "timeBox"
        // Social
        case .syncWith(let p): return "syncWith.\(p)"
        case .officeHours: return "officeHours"
        case .pairWork(let p, _): return "pairWork.\(p)"
        case .noOverlap: return "noOverlap"
        // Health
        case .microBreak: return "microBreak"
        case .walkBreak: return "walkBreak"
        case .pinAt(let t, _, _): return "pinAt.\(t)"
        case .noScreensAfter: return "noScreensAfter"
        // Context
        case .batchByTool(let t): return "batchByTool.\(t)"
        case .deepShallowSplit: return "deepShallowSplit"
        case .groupByLocation: return "groupByLocation"
        case .uninterruptedBlock(let p, _): return "uninterruptedBlock.\(p)"
        // Adaptive
        case .stretchGoals: return "stretchGoals"
        case .overflowToTomorrow: return "overflowToTomorrow"
        case .energyCheckIn: return "energyCheckIn"
        // Temporal
        case .todayOnly: return "todayOnly"
        case .until: return "until"
        case .skipWeekends: return "skipWeekends"
        // Sources
        case .fromCalendar(let n): return "fromCalendar.\(n)"
        case .fromProject(let n): return "fromProject.\(n)"
        case .fromTimeRange: return "fromTimeRange"
        // Transforms
        case .splitLong: return "splitLong"
        case .addBuffer: return "addBuffer"
        case .capTotal: return "capTotal"
        case .mergeAdjacent(let c): return "mergeAdjacent.\(c)"
        // Conditions
        case .when(let c, _, _): return "when.\(c.label)"
        // Output
        case .autoApply: return "autoApply"
        case .notify: return "notify"
        case .chainThen: return "chainThen"
        case .saveAsPreset(let n): return "saveAsPreset.\(n)"
        // Triggers
        case .onEventDeleted: return "onEventDeleted"
        case .onNewEvent: return "onNewEvent"
        case .daily(let h): return "daily.\(h)"
        case .weekly(let d): return "weekly.\(d)"
        case .onCalendarSync: return "onCalendarSync"
        }
    }

    // MARK: - Phase Classification

    static func phase(for intent: ScheduleIntent) -> Phase {
        switch intent {
        // Trigger
        case .onEventDeleted, .onNewEvent, .daily, .weekly, .onCalendarSync:
            return .trigger
        // Source
        case .fromCalendar, .fromProject, .fromTimeRange:
            return .source
        // Context
        case .noEventsBefore, .noEventsAfter, .workingHours, .horizon:
            return .context
        // Tasks
        case .includeBacklog, .includeBacklogTasks, .findSlotsForBacklog:
            return .tasks
        // Create
        case .focusBlock, .createBlock, .pomodoroSession:
            return .create
        // Transform
        case .splitLong, .addBuffer, .capTotal, .mergeAdjacent:
            return .transform
        // Weights
        case .prioritizeDeadlines, .prioritizeFocus, .minimizeContextSwitching,
             .groupByProject, .batchMeetings:
            return .weights
        // Energy
        case .lowEnergy, .peakEnergy, .morningPerson, .protectLunch,
             .breakEvery, .maxMeetings,
             .contingencyBuffer, .focusProtection, .meetingPrep, .windDown,
             .warmUp, .coolDown, .travelBuffer, .endOfDayReview,
             .likeYesterday, .halfDay, .matchEnergyCurve,
             .microBreak, .walkBreak, .noScreensAfter:
            return .energy
        // Social
        case .syncWith, .officeHours, .pairWork, .noOverlap:
            return .context
        // Create (pinned events)
        case .pinAt:
            return .create
        // Rules
        case .keepFixed, .exclude, .onlyOptimize, .preferPeriod, .stability,
             .taskOrder, .minGap, .flexDuration, .timeBox,
             .batchByTool, .deepShallowSplit, .groupByLocation, .uninterruptedBlock:
            return .rules
        // Output
        case .stretchGoals, .overflowToTomorrow, .energyCheckIn:
            return .output
        // Temporal scope → context phase
        case .todayOnly, .until, .skipWeekends:
            return .context
        // Condition
        case .when:
            return .condition
        // Config
        case .speed, .scenarios:
            return .config
        // Output
        case .autoApply, .notify, .chainThen, .saveAsPreset:
            return .output
        }
    }

    // MARK: - Dependency Rules

    /// Required dependencies: if you add X, you need Y.
    static func dependencies(for intent: ScheduleIntent) -> [ScheduleIntent] {
        switch intent {
        case .prioritizeDeadlines:
            return [.includeBacklog]
        case .findSlotsForBacklog:
            return [.includeBacklog]
        case .groupByProject:
            return [.includeBacklog]
        case .splitLong:
            return [.includeBacklog]
        case .mergeAdjacent:
            return [.includeBacklog]
        case .chainThen:
            return [.autoApply]  // chains need auto-apply to proceed
        default:
            return []
        }
    }

    /// Soft suggestions: if you add X, you might want Y.
    static func suggestions(for intent: ScheduleIntent) -> [ScheduleIntent] {
        switch intent {
        case .focusBlock:
            return [.prioritizeFocus(), .minimizeContextSwitching(), .focusProtection(bufferMinutes: 15), .warmUp(minutes: 10)]
        case .lowEnergy:
            return [.breakEvery(workMinutes: 45, breakMinutes: 15), .protectLunch(), .maxMeetings(perDay: 3)]
        case .morningPerson:
            return [.peakEnergy(hour: 9)]
        case .includeBacklog:
            return [.prioritizeDeadlines()]
        case .batchMeetings:
            return [.protectLunch()]
        case .pomodoroSession:
            return [.prioritizeFocus()]
        case .splitLong:
            return [.addBuffer(minutes: 5)]
        case .capTotal:
            return [.breakEvery(workMinutes: 60, breakMinutes: 10)]
        case .daily:
            return [.autoApply]  // daily triggers should auto-apply
        case .onEventDeleted:
            return [.stability(.conservative), .autoApply]
        case .fromProject:
            return [.groupByProject()]
        case .meetingPrep:
            return [.travelBuffer(minutes: 15)]
        case .halfDay(.morningOnly):
            return [.morningPerson]
        case .matchEnergyCurve:
            return [.peakEnergy(hour: 10)]
        case .microBreak:
            return [.walkBreak(afterMinutes: 90, durationMinutes: 10)]
        case .deepShallowSplit:
            return [.minimizeContextSwitching(), .matchEnergyCurve]
        case .uninterruptedBlock:
            return [.focusProtection(bufferMinutes: 15), .minimizeContextSwitching()]
        case .officeHours:
            return [.batchMeetings()]
        case .overflowToTomorrow:
            return [.includeBacklog]
        case .stretchGoals:
            return [.includeBacklog]
        default:
            return []
        }
    }

    // MARK: - Conflict Rules

    /// Returns a human-readable reason if two intents conflict, nil if compatible.
    static func conflictReason(_ a: ScheduleIntent, _ b: ScheduleIntent) -> String? {
        switch (a, b) {
        case (.noEventsBefore(let h), .morningPerson) where h >= 11,
             (.morningPerson, .noEventsBefore(let h)) where h >= 11:
            return "Morning blocked until \(h):00 but morning schedule requested"

        case (.noEventsBefore(let bh), .noEventsAfter(let ah)),
             (.noEventsAfter(let ah), .noEventsBefore(let bh)):
            if ah - bh < 2 {
                return "Working window only \(ah - bh)h — too short"
            }
            return nil

        case (.lowEnergy, .prioritizeFocus(let w)),
             (.prioritizeFocus(let w), .lowEnergy):
            if w > 1.5 {
                return "Low energy conflicts with aggressive focus (weight \(w))"
            }
            return nil

        case (.noEventsBefore(let h), .focusBlock(_, let period)),
             (.focusBlock(_, let period), .noEventsBefore(let h)):
            if let p = period, p == .morning && h >= 11 {
                return "Morning focus blocked by noEventsBefore(\(h))"
            }
            return nil

        case (.stability(.full), .stability(.conservative)),
             (.stability(.conservative), .stability(.full)):
            return "Contradictory stability settings"

        default:
            return nil
        }
    }

    // MARK: - Known Intents (for suggestions)

    static let allKnownIntents: [ScheduleIntent] = [
        // Triggers
        .onEventDeleted, .onNewEvent, .daily(hour: 9), .weekly(day: 2), .onCalendarSync,
        // Sources
        .fromCalendar(name: "Work"), .fromProject(name: ""),
        // Context
        .noEventsBefore(hour: 11), .noEventsAfter(hour: 17),
        .horizon(.today), .horizon(.tomorrow), .horizon(.week),
        // Tasks
        .includeBacklog, .findSlotsForBacklog,
        // Create
        .focusBlock(minutes: 120), .pomodoroSession(),
        // Transforms
        .splitLong(maxMinutes: 90), .addBuffer(minutes: 10),
        .capTotal(minutesPerDay: 360),
        // Weights
        .prioritizeDeadlines(), .prioritizeFocus(),
        .minimizeContextSwitching(), .groupByProject(), .batchMeetings(),
        // Energy
        .lowEnergy, .morningPerson, .protectLunch(),
        .breakEvery(workMinutes: 60, breakMinutes: 10),
        .maxMeetings(perDay: 3),
        // Rules
        .stability(.normal), .stability(.conservative),
        // Config
        .speed(.quick), .speed(.balanced), .speed(.thorough),
        // Smart scheduling
        .contingencyBuffer(percent: 20),
        .focusProtection(bufferMinutes: 15),
        .meetingPrep(minutes: 10),
        .windDown(lastHours: 2),
        .taskOrder(.hardestFirst), .taskOrder(.shortestFirst), .taskOrder(.urgentFirst),
        .minGap(minutes: 10),
        .matchEnergyCurve,
        .warmUp(minutes: 15), .coolDown(minutes: 10),
        .travelBuffer(minutes: 15),
        .endOfDayReview(minutes: 15),
        .timeBox(maxMinutes: 90),
        .halfDay(.morningOnly), .halfDay(.afternoonOnly),
        .likeYesterday,
        // Social
        .officeHours(start: 14, end: 16),
        .noOverlap,
        // Health
        .microBreak(everyMinutes: 60, durationMinutes: 5),
        .walkBreak(afterMinutes: 90, durationMinutes: 10),
        .noScreensAfter(hour: 20),
        // Context
        .deepShallowSplit(deepPeriod: .morning, shallowPeriod: .afternoon),
        .groupByLocation,
        // Adaptive
        .stretchGoals(maxExtra: 2),
        .overflowToTomorrow,
        .energyCheckIn(atHour: 14),
        .skipWeekends,
        // Output
        .autoApply, .saveAsPreset(name: ""),
    ]
}

// MARK: - Phase Display Names

extension IntentGraph.Phase {
    var displayName: String {
        switch self {
        case .trigger: return "Trigger"
        case .source: return "Source"
        case .context: return "When"
        case .tasks: return "Tasks"
        case .create: return "Create"
        case .transform: return "Transform"
        case .weights: return "Priorities"
        case .energy: return "Energy"
        case .rules: return "Rules"
        case .condition: return "Condition"
        case .config: return "Config"
        case .output: return "Output"
        }
    }
}
