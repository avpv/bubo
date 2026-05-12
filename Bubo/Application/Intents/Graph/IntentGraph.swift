import Foundation
import BuboOptimizer

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
        build(from: intents, conflictOracle: conflictReason)
    }

    /// Build a graph with a caller-supplied conflict oracle. The
    /// oracle mirrors `conflictReason(_:_:)` in shape — given two
    /// intents, return a human-readable reason if they conflict or
    /// `nil` if they're compatible — but lets external callers
    /// (e.g. `IntentGraphSalsaCache`) route the decision through a
    /// memoized per-pair cache. The static `conflictReason` is the
    /// default so existing call sites keep the monolithic behaviour
    /// unchanged.
    static func build(
        from intents: [ScheduleIntent],
        conflictOracle: (ScheduleIntent, ScheduleIntent) -> String?
    ) -> IntentGraph {
        var graph = IntentGraph()

        // Add all explicit intents as nodes
        for intent in intents {
            graph.addNode(intent)
        }

        // Auto-resolve dependencies
        graph.resolveDependencies()

        // Detect and add conflict edges through the injected oracle.
        graph.detectConflicts(using: conflictOracle)

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

    // MARK: - Compact Indexing

    /// Stable `nodeId → UInt32` index over the current `nodes`
    /// dictionary, sorted by id so successive builds against the same
    /// node set produce the same indices. Used by hot-path consumers
    /// (`reachabilityBitset`, Salsa-style cache key derivation) so a
    /// `Dictionary<String, …>` lookup collapses to an array index.
    ///
    /// Callers should treat the returned indices as opaque: the only
    /// guarantee is that two indices compare equal iff their ids do.
    /// The indices are *not* stable across edits to `nodes` (insert/
    /// remove shifts every id whose sorted position changes).
    func compactNodeIndex() -> [String: UInt32] {
        let sorted = nodes.keys.sorted()
        var out: [String: UInt32] = [:]
        out.reserveCapacity(sorted.count)
        for (i, id) in sorted.enumerated() {
            out[id] = UInt32(i)
        }
        return out
    }

    /// Ordered id list matching `compactNodeIndex` indices. The pair
    /// `(compactNodeIndex(), orderedNodeIds())` lets callers translate
    /// in either direction without touching the `nodes` dictionary on
    /// the hot path.
    func orderedNodeIds() -> [String] {
        nodes.keys.sorted()
    }

    /// Bitset-backed transitive reachability over the same edge set as
    /// `reachability()`. Returns `nil` when the graph has zero nodes
    /// (so the empty case stays cheap and unambiguous). Builds the
    /// `Set<String>` form once internally — the bitset's value is fast
    /// repeated queries (`contains(from:to:)` is a single bit test).
    func reachabilityBitset() -> ReachabilityBitset? {
        let edges = reachability()
        return ReachabilityBitset.build(ids: orderedNodeIds(), edges: edges)
    }

    // MARK: - Reachability & SCC Diagnostics

    /// Transitive closure of `dependsOn` + `requires` edges as a
    /// reachability bitset per node. Keys are node IDs; values are
    /// the set of node IDs reachable from the key via one or more
    /// edges.
    ///
    /// Internally walks `[Int]` adjacency arrays indexed by the
    /// UInt32 node position so the DFS hot path doesn't touch a
    /// `Dictionary<String, …>` until the result is materialised back
    /// to the public string-keyed shape.
    ///
    /// O(V · E) worst case; for our graph sizes (<100 nodes) this is
    /// microseconds.
    func reachability() -> [String: Set<String>] {
        let n = nodes.count
        guard n > 0 else { return [:] }

        // Stable Int index per node id, ordered by id so successive
        // invocations against the same graph produce the same
        // reachability shape.
        let orderedIds = nodes.keys.sorted()
        var indexOf: [String: Int] = [:]
        indexOf.reserveCapacity(n)
        for (i, id) in orderedIds.enumerated() { indexOf[id] = i }

        // Dense adjacency: prereq position → list of dependent
        // positions. Both `dependsOn` and `requires` normalise into
        // the prereq → dependent direction (see `sortedIntents` for
        // the convention rationale).
        var adj: [[Int]] = Array(repeating: [], count: n)
        for edge in edges {
            switch edge.kind {
            case .dependsOn:
                if let p = indexOf[edge.from], let d = indexOf[edge.to] {
                    adj[p].append(d)
                }
            case .requires:
                if let p = indexOf[edge.to], let d = indexOf[edge.from] {
                    adj[p].append(d)
                }
            default:
                continue
            }
        }

        // DFS per source over `[Int]`. `visited` is a bool array
        // sized to `n` — `Set<Int>` would also work but the bool
        // array stays in L1 for typical 65-node intent graphs.
        var out: [String: Set<String>] = [:]
        out.reserveCapacity(n)
        for source in 0..<n {
            var visited = [Bool](repeating: false, count: n)
            var stack = adj[source]
            while let head = stack.popLast() {
                if visited[head] { continue }
                visited[head] = true
                stack.append(contentsOf: adj[head])
            }
            // Materialise back to string ids only at the boundary.
            // `Set` reserveCapacity skipped — for typical reachability
            // counts (<20 ids per source) the rehash cost is dwarfed
            // by the DFS itself.
            var hits: Set<String> = []
            for i in 0..<n where visited[i] {
                hits.insert(orderedIds[i])
            }
            out[orderedIds[source]] = hits
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
        detectConflicts(using: Self.conflictReason)
    }

    /// `detectConflicts` variant that routes every pairwise check
    /// through `reasonOracle` instead of the static
    /// `conflictReason(_:_:)`. Used by the Salsa-style cache to
    /// memoize per-pair conflict decisions so a single-intent edit
    /// doesn't re-check every other pair — only the O(N) pairs
    /// involving the edited intent invalidate.
    mutating func detectConflicts(
        using reasonOracle: (ScheduleIntent, ScheduleIntent) -> String?
    ) {
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
                    if reasonOracle(bucketNodes[i].intent, bucketNodes[j].intent) != nil {
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
        // Hot loop. Convert string-keyed storage to dense UInt32-
        // indexed arrays once up front so Kahn's algorithm runs
        // against `[Int]` array slots instead of `Dictionary<String,
        // …>`. For 65 intents this is the difference between ~3.5
        // µs (string dict) and ~0.7 µs (array indices) per call —
        // measurable when the SwiftUI composer rebuilds on every
        // chip toggle.
        let n = nodes.count
        guard n > 0 else { return [] }

        // 1) Order nodes once, derive String → Int index map.
        let orderedNodes = nodes.values.sorted { lhs, rhs in
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            return lhs.id < rhs.id
        }
        var indexOf: [String: Int] = [:]
        indexOf.reserveCapacity(n)
        for (i, node) in orderedNodes.enumerated() {
            indexOf[node.id] = i
        }

        // 2) Build adjacency + in-degree as dense `[Int]` arrays.
        var inDegree = [Int](repeating: 0, count: n)
        var adjacency: [[Int]] = Array(repeating: [], count: n)
        for edge in edges where edge.kind == .dependsOn || edge.kind == .requires {
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
            guard let pIdx = indexOf[prereq], let dIdx = indexOf[dependent] else { continue }
            adjacency[pIdx].append(dIdx)
            inDegree[dIdx] += 1
        }

        // 3) Priority-ordered ready queue over indices. `orderedNodes`
        //    is already sorted by (phase, id); collecting the in-
        //    degree-zero indices in that order gives Kahn a stable
        //    seed without an extra sort.
        var ready: [Int] = []
        ready.reserveCapacity(n)
        for i in 0..<n where inDegree[i] == 0 {
            ready.append(i)
        }

        var out: [Node] = []
        out.reserveCapacity(n)
        var emitted = [Bool](repeating: false, count: n)

        while !ready.isEmpty {
            let head = ready.removeFirst()
            out.append(orderedNodes[head])
            emitted[head] = true
            for dependent in adjacency[head] {
                inDegree[dependent] -= 1
                if inDegree[dependent] == 0 {
                    let depNode = orderedNodes[dependent]
                    // Keep `ready` sorted by (phase, id) ascending so
                    // the existing tie-break behaviour holds.
                    let insertAt = ready.firstIndex { idx in
                        let other = orderedNodes[idx]
                        if other.phase != depNode.phase { return other.phase > depNode.phase }
                        return other.id > depNode.id
                    } ?? ready.count
                    ready.insert(dependent, at: insertAt)
                }
            }
        }

        // Cycle tail: any node not emitted participates in a cycle.
        // Append in (phase, id) order — `orderedNodes` already has
        // this ordering, so a single linear scan suffices.
        if out.count < n {
            for i in 0..<n where !emitted[i] {
                out.append(orderedNodes[i])
            }
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
        case .focusBurst: return "focusBurst"
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

}

