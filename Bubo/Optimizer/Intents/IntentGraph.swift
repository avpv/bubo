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
    ///
    /// Uses a Kahn-style forward propagation queue instead of the old
    /// fixed-point `while changed` loop: every newly-added node is pushed
    /// onto a work queue, so we only re-scan dependencies for nodes that
    /// have changed. Complexity drops from O(depth × N) to O(edges).
    mutating func resolveDependencies() {
        var queue: [ScheduleIntent] = nodes.values.map(\.intent)
        while let intent = queue.first {
            queue.removeFirst()
            for dep in Self.dependencies(for: intent) {
                let depId = nodeId(for: dep)
                guard nodes[depId] == nil else { continue }
                addNode(dep, isAutoResolved: true)
                addEdge(from: intent, to: dep, kind: .requires)
                queue.append(dep)
            }
        }
    }

    // MARK: - Reachability & SCC Diagnostics

    /// Transitive closure of `dependsOn` + `requires` edges as a
    /// reachability bitset per node. Keys are node IDs; values are the
    /// set of node IDs reachable from the key via one or more edges.
    /// Memoized by computation — callers cache the result per graph
    /// instance. O(V · E) worst case; for our graph sizes (<100 nodes)
    /// this is microseconds.
    func reachability() -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        // Normalise both edge kinds to (prereq → dependent) so the
        // reachability relation tracks "what depends on this node"
        // rather than the raw edge direction (see sortedIntents for
        // the convention rationale).
        var adj: [String: [String]] = [:]
        for edge in edges {
            switch edge.kind {
            case .dependsOn:
                adj[edge.from, default: []].append(edge.to)
            case .requires:
                adj[edge.to, default: []].append(edge.from)
            default: continue
            }
        }
        for nodeId in nodes.keys {
            var visited: Set<String> = []
            var stack = adj[nodeId] ?? []
            while let head = stack.popLast() {
                guard visited.insert(head).inserted else { continue }
                stack.append(contentsOf: adj[head] ?? [])
            }
            out[nodeId] = visited
        }
        return out
    }

    /// Detect strongly-connected components larger than one node via
    /// Tarjan's algorithm over `dependsOn`+`requires` edges. A non-empty
    /// result means the graph has a cycle — a data-integrity bug that
    /// breaks topological sort. Returned components are lists of node
    /// IDs in the cycle.
    func stronglyConnectedComponents() -> [[String]] {
        // Normalise both edge kinds into the prereq→dependent
        // convention so SCC detection runs on the same DAG the
        // topological sort is meant to see.
        var adj: [String: [String]] = [:]
        for edge in edges {
            switch edge.kind {
            case .dependsOn:
                adj[edge.from, default: []].append(edge.to)
            case .requires:
                adj[edge.to, default: []].append(edge.from)
            default: continue
            }
        }

        // Iterative Tarjan using an explicit work stack so very deep
        // cycles can't blow the call stack. Each work-stack frame
        // remembers the vertex being processed and the next
        // successor index to explore — effectively a saved
        // continuation of the recursive version.
        var index = 0
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var onStack: Set<String> = []
        var tarjanStack: [String] = []
        var result: [[String]] = []

        struct Frame {
            let vertex: String
            var successors: [String]
            var cursor: Int
        }
        var work: [Frame] = []

        for root in nodes.keys where indices[root] == nil {
            // Open a fresh frame for `root`.
            indices[root] = index
            lowlink[root] = index
            index += 1
            tarjanStack.append(root)
            onStack.insert(root)
            work.append(Frame(vertex: root, successors: adj[root] ?? [], cursor: 0))

            while !work.isEmpty {
                var frame = work.removeLast()
                var recursed = false

                // Advance through remaining successors.
                while frame.cursor < frame.successors.count {
                    let w = frame.successors[frame.cursor]
                    frame.cursor += 1
                    if indices[w] == nil {
                        // Simulate recursive call: save the current
                        // frame (now at cursor past `w`), push a new
                        // frame for `w`.
                        indices[w] = index
                        lowlink[w] = index
                        index += 1
                        tarjanStack.append(w)
                        onStack.insert(w)
                        work.append(frame)
                        work.append(Frame(vertex: w, successors: adj[w] ?? [], cursor: 0))
                        recursed = true
                        break
                    } else if onStack.contains(w) {
                        lowlink[frame.vertex] = min(
                            lowlink[frame.vertex] ?? 0,
                            indices[w] ?? 0
                        )
                    }
                }

                if recursed { continue }

                // All successors of `frame.vertex` exhausted. Fold its
                // lowlink into the parent (if any) and pop a component
                // when this vertex is a root.
                let v = frame.vertex
                if lowlink[v] == indices[v] {
                    var component: [String] = []
                    while let w = tarjanStack.popLast() {
                        onStack.remove(w)
                        component.append(w)
                        if w == v { break }
                    }
                    if component.count > 1 { result.append(component) }
                }
                // Propagate lowlink back to the caller, which is the
                // top of `work` (if it exists).
                if let parentIdx = work.indices.last {
                    let parent = work[parentIdx].vertex
                    lowlink[parent] = min(
                        lowlink[parent] ?? 0,
                        lowlink[v] ?? 0
                    )
                }
            }
        }
        return result
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

    /// Category used to bucket intents for O(N × k) conflict detection —
    /// k being the small number of intents in the same bucket instead
    /// of the old O(N²) full pairwise scan.
    private enum ConflictBucket: Hashable {
        case timeWindow   // noEventsBefore / noEventsAfter / morningPerson / focusBlock
        case energy       // lowEnergy / prioritizeFocus
        case stability    // stability(.*)
        case none
    }

    private static func conflictBucket(for intent: ScheduleIntent) -> ConflictBucket {
        switch intent {
        case .noEventsBefore, .noEventsAfter, .morningPerson, .focusBlock:
            return .timeWindow
        case .lowEnergy, .prioritizeFocus:
            return .energy
        case .stability:
            return .stability
        default:
            return .none
        }
    }

    /// Detect conflicts between intents using a category index.
    ///
    /// The old implementation was O(N²) pairwise — for 30 intents that's
    /// 435 comparisons, most hitting the default "no conflict" branch in
    /// `conflictReason`. Bucketing by `ConflictBucket` first restricts
    /// the quadratic sweep to intents that can actually conflict with
    /// each other, trimming work by 10–20× on real intent lists.
    mutating func detectConflicts() {
        var buckets: [ConflictBucket: [Node]] = [:]
        for node in nodes.values {
            let bucket = Self.conflictBucket(for: node.intent)
            guard bucket != .none else { continue }
            buckets[bucket, default: []].append(node)
        }

        for (_, bucketNodes) in buckets {
            guard bucketNodes.count > 1 else { continue }
            for i in 0..<bucketNodes.count {
                for j in (i + 1)..<bucketNodes.count {
                    if Self.conflictReason(bucketNodes[i].intent, bucketNodes[j].intent) != nil {
                        addEdge(from: bucketNodes[i].intent, to: bucketNodes[j].intent, kind: .conflicts)
                    }
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

    /// Return intents in correct compilation order.
    ///
    /// Uses Kahn's algorithm on the dependency+requires edge set, with
    /// phase as a secondary ordering key so nodes whose edges don't
    /// span phases still compile in phase order. Cycles degrade
    /// gracefully: any node left in the work set after Kahn finishes
    /// is appended at the end in phase order, preserving the pre-
    /// topological behaviour rather than crashing the compiler on a
    /// malformed graph. Call `stronglyConnectedComponents()` on the
    /// same graph to surface the offending cycles in telemetry.
    func sortedIntents() -> [ScheduleIntent] {
        // Build reverse adjacency (dependency -> dependents) and in-degree
        // on ordering-relevant edges. `requires` is folded in because
        // auto-resolved prerequisites must be emitted before the nodes
        // that requested them.
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]
        for nodeId in nodes.keys { inDegree[nodeId] = 0 }

        for edge in edges where edge.kind == .dependsOn || edge.kind == .requires {
            // `dependsOn`: `from` must come before `to`. `requires`:
            // `from` requires `to` to be present — `to` is the
            // prerequisite, so must also come first. Normalise both
            // to an edge pointing from the prerequisite to the
            // dependent, then Kahn over that.
            // Edge conventions (see EdgeKind docs):
            //   `dependsOn`: from must be resolved before to → from is prereq
            //   `requires`:  from requires to to be present → to is prereq
            // Normalise both into (prereq → dependent) so Kahn sees a
            // single consistent DAG.
            let prereq: String
            let dependent: String
            switch edge.kind {
            case .dependsOn:
                prereq = edge.from
                dependent = edge.to
            case .requires:
                prereq = edge.to
                dependent = edge.from
            default:
                continue
            }
            guard nodes[prereq] != nil, nodes[dependent] != nil else { continue }
            adjacency[prereq, default: []].append(dependent)
            inDegree[dependent, default: 0] += 1
        }

        // Priority-ordered ready queue: nodes whose prerequisites are
        // all emitted become eligible. Tie-break by phase so nodes
        // from the same "logical stage" of the pipeline stay grouped.
        var ready = nodes.values
            .filter { (inDegree[$0.id] ?? 0) == 0 }
            .sorted { lhs, rhs in
                if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
                return lhs.id < rhs.id
            }

        var out: [Node] = []
        out.reserveCapacity(nodes.count)
        while !ready.isEmpty {
            let head = ready.removeFirst()
            out.append(head)
            for dependent in adjacency[head.id] ?? [] {
                let next = (inDegree[dependent] ?? 0) - 1
                inDegree[dependent] = next
                if next == 0, let dependentNode = nodes[dependent] {
                    // Keep `ready` sorted by phase ascending.
                    let insertAt = ready.firstIndex { n in
                        if n.phase != dependentNode.phase { return n.phase > dependentNode.phase }
                        return n.id > dependentNode.id
                    } ?? ready.count
                    ready.insert(dependentNode, at: insertAt)
                }
            }
        }

        // Cycle tail: any node still carrying positive in-degree
        // participates in a cycle. Append in phase order so the
        // compiler can still make progress, and let
        // `stronglyConnectedComponents()` surface the bug separately.
        if out.count < nodes.count {
            let emitted = Set(out.map(\.id))
            let leftovers = nodes.values
                .filter { !emitted.contains($0.id) }
                .sorted { lhs, rhs in
                    if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
                    return lhs.id < rhs.id
                }
            out.append(contentsOf: leftovers)
        }

        return out.map(\.intent)
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
        case .limitToTopTasks(let c): return "limitToTopTasks.\(c)"
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
        case .includeBacklog, .includeBacklogTasks, .limitToTopTasks, .findSlotsForBacklog:
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
        .focusBlock(minutes: 120), .pomodoroSession,
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
