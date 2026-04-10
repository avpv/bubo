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
    enum Phase: Int, Comparable, CaseIterable, Sendable {
        case context = 0    // horizon, workingHours, noEventsBefore/After
        case tasks = 1      // includeBacklog, findSlotsForBacklog
        case create = 2     // focusBlock, createBlock, pomodoroSession
        case weights = 3    // prioritizeDeadlines, prioritizeFocus, batchMeetings
        case energy = 4     // lowEnergy, morningPerson, breakEvery, protectLunch
        case rules = 5      // keepFixed, exclude, onlyOptimize, preferPeriod
        case config = 6     // speed, stability, scenarios

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
                if let reason = Self.conflictReason(nodeList[i].intent, nodeList[j].intent) {
                    addEdge(from: nodeList[i].intent, to: nodeList[j].intent, kind: .conflicts)
                    _ = reason  // stored in edge, used by conflict detector
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
        }
    }

    // MARK: - Phase Classification

    static func phase(for intent: ScheduleIntent) -> Phase {
        switch intent {
        case .noEventsBefore, .noEventsAfter, .workingHours, .horizon:
            return .context
        case .includeBacklog, .includeBacklogTasks, .findSlotsForBacklog:
            return .tasks
        case .focusBlock, .createBlock, .pomodoroSession:
            return .create
        case .prioritizeDeadlines, .prioritizeFocus, .minimizeContextSwitching,
             .groupByProject, .batchMeetings:
            return .weights
        case .lowEnergy, .peakEnergy, .morningPerson, .protectLunch,
             .breakEvery, .maxMeetings:
            return .energy
        case .keepFixed, .exclude, .onlyOptimize, .preferPeriod, .stability:
            return .rules
        case .speed, .scenarios:
            return .config
        }
    }

    // MARK: - Dependency Rules

    /// Required dependencies: if you add X, you need Y.
    static func dependencies(for intent: ScheduleIntent) -> [ScheduleIntent] {
        switch intent {
        case .prioritizeDeadlines:
            // Deadline prioritization only makes sense with backlog tasks
            return [.includeBacklog]
        case .findSlotsForBacklog:
            // Slot-finding implies backlog inclusion
            return [.includeBacklog]
        case .groupByProject:
            // Grouping needs existing events
            return [.includeBacklog]
        default:
            return []
        }
    }

    /// Soft suggestions: if you add X, you might want Y.
    static func suggestions(for intent: ScheduleIntent) -> [ScheduleIntent] {
        switch intent {
        case .focusBlock:
            return [.prioritizeFocus(), .minimizeContextSwitching()]
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
        .noEventsBefore(hour: 11), .noEventsAfter(hour: 17),
        .horizon(.today), .horizon(.tomorrow), .horizon(.week),
        .focusBlock(minutes: 120), .pomodoroSession(),
        .prioritizeDeadlines(), .prioritizeFocus(),
        .minimizeContextSwitching(), .groupByProject(), .batchMeetings(),
        .lowEnergy, .morningPerson, .protectLunch(),
        .breakEvery(workMinutes: 60, breakMinutes: 10),
        .maxMeetings(perDay: 3),
        .includeBacklog, .findSlotsForBacklog,
        .stability(.normal), .stability(.conservative),
        .speed(.quick), .speed(.balanced), .speed(.thorough),
    ]
}

// MARK: - Phase Display Names

extension IntentGraph.Phase {
    var displayName: String {
        switch self {
        case .context: return "When"
        case .tasks: return "Tasks"
        case .create: return "Create"
        case .weights: return "Priorities"
        case .energy: return "Energy"
        case .rules: return "Rules"
        case .config: return "Config"
        }
    }
}
