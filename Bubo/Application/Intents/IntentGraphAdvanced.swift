import Foundation
import BuboDomain
import BuboOptimizer

// MARK: - Subgraphs, Ports, Parallel Branches, Variables
//
// Extensions to IntentGraph that add:
// 1. Subgraphs — named, nestable, saveable groups of nodes
// 2. Typed ports — explicit data flow between nodes
// 3. Parallel branches — split/merge for independent strategies
// 4. Variables — named parameters referenced by nodes

// MARK: - 1. Subgraphs

/// A named, reusable group of intents that acts as a single node.
/// Subgraphs can contain other subgraphs (nesting).
/// When compiled, they expand into their constituent intents.
struct Subgraph: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var description: String?
    var intents: [ScheduleIntent]
    /// Nested subgraph references (by ID).
    var children: [String] = []
    /// Input variables this subgraph expects.
    var inputs: [PipelineVariable] = []
    /// Whether this was saved by the user (vs. built-in).
    var isUserCreated: Bool = false

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        intents: [ScheduleIntent],
        children: [String] = [],
        inputs: [PipelineVariable] = [],
        isUserCreated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.intents = intents
        self.children = children
        self.inputs = inputs
        self.isUserCreated = isUserCreated
    }

    /// Expand this subgraph into a flat list of intents,
    /// recursively expanding nested subgraphs.
    func expand(subgraphs: [String: Subgraph], variables: [String: PipelineValue] = [:]) -> [ScheduleIntent] {
        var result: [ScheduleIntent] = []

        // Apply variable substitutions to our intents
        let resolvedIntents = intents.map { intent in
            intent.applyVariables(variables)
        }
        result.append(contentsOf: resolvedIntents)

        // Expand children recursively
        for childId in children {
            if let child = subgraphs[childId] {
                result.append(contentsOf: child.expand(subgraphs: subgraphs, variables: variables))
            }
        }

        return result
    }
}

// MARK: - Subgraph Registry

/// Stores and retrieves subgraphs by ID.
/// Built-in presets + user-saved subgraphs.
@MainActor
@Observable
final class SubgraphRegistry {
    private(set) var subgraphs: [String: Subgraph] = [:]

    private let persistenceKey = "BuboSubgraphRegistry"

    init() {
        registerBuiltins()
        loadUserSubgraphs()
    }

    func subgraph(id: String) -> Subgraph? {
        subgraphs[id]
    }

    func register(_ subgraph: Subgraph) {
        subgraphs[subgraph.id] = subgraph
        if subgraph.isUserCreated { saveUserSubgraphs() }
    }

    func remove(id: String) {
        subgraphs.removeValue(forKey: id)
        saveUserSubgraphs()
    }

    var userSubgraphs: [Subgraph] {
        subgraphs.values.filter(\.isUserCreated).sorted { $0.name < $1.name }
    }

    var builtinSubgraphs: [Subgraph] {
        subgraphs.values.filter { !$0.isUserCreated }.sorted { $0.name < $1.name }
    }

    // MARK: - Built-in Subgraphs

    private func registerBuiltins() {
        register(Subgraph(
            id: "morning-routine",
            name: "Morning Routine",
            description: "Focus-heavy morning with context protection",
            intents: [
                .focusBlock(minutes: 120, period: .morning),
                .prioritizeFocus(),
                .minimizeContextSwitching(),
                .noEventsBefore(hour: 9),
            ]
        ))

        register(Subgraph(
            id: "meeting-day",
            name: "Meeting Day",
            description: "Batch meetings, protect lunch, add buffers",
            intents: [
                .batchMeetings(),
                .protectLunch(),
                .addBuffer(minutes: 10),
                .maxMeetings(perDay: 6),
            ]
        ))

        register(Subgraph(
            id: "deadline-push",
            name: "Deadline Push",
            description: "Maximize deadline task time, minimal meetings",
            intents: [
                .prioritizeDeadlines(weight: 3.0),
                .includeBacklog,
                .maxMeetings(perDay: 2),
                .stability(.full),
            ]
        ))

        register(Subgraph(
            id: "low-energy-afternoon",
            name: "Low Energy Afternoon",
            description: "Easy tasks after lunch, frequent breaks",
            intents: [
                .lowEnergy,
                .breakEvery(workMinutes: 45, breakMinutes: 15),
                .protectLunch(),
                .noEventsAfter(hour: 17),
            ]
        ))

        register(Subgraph(
            id: "deep-work-session",
            name: "Deep Work Session",
            description: "Long uninterrupted focus with pomodoro",
            intents: [
                .focusBlock(minutes: 180, period: .morning),
                .pomodoroSession,
                .minimizeContextSwitching(weight: 2.0),
                .maxMeetings(perDay: 1),
            ],
            inputs: [
                PipelineVariable(name: "duration", type: .int, defaultValue: .int(180)),
            ]
        ))
    }

    // MARK: - Persistence

    private func saveUserSubgraphs() {
        let user = subgraphs.values.filter(\.isUserCreated)
        if let data = try? JSONEncoder().encode(Array(user)) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
            CloudSyncService.shared.push(persistenceKey)
        }
    }

    private func loadUserSubgraphs() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let saved = try? JSONDecoder().decode([Subgraph].self, from: data) else { return }
        for sg in saved {
            subgraphs[sg.id] = sg
        }
    }
}

// MARK: - 2. Typed Ports

/// Defines the data type that flows between nodes.
/// Each node has input and output port types.
enum PortType: String, Codable, Hashable, Sendable {
    case events       // [OptimizableEvent]
    case preferences  // OptimizerPreferences
    case schedule     // [ScheduleGene] (GA output)
    case config       // GAConfiguration
    case trigger      // Void (activation signal)
    case condition    // Bool
}

/// A typed connection between two nodes.
struct Port: Codable, Hashable, Sendable {
    let nodeId: String
    let direction: Direction
    let type: PortType

    enum Direction: String, Codable, Hashable, Sendable {
        case input
        case output
    }
}

/// Defines input/output ports for each intent category.
extension ScheduleIntent {
    var inputPorts: [PortType] {
        switch category {
        case .trigger: return []
        case .source: return [.trigger]
        case .time, .tasks: return [.events]
        case .create: return [.events]
        case .transform: return [.events]
        case .weights, .energy: return [.preferences]
        case .rules: return [.events, .preferences]
        case .condition: return [.events, .condition]
        case .social: return [.events, .preferences]
        case .meta: return [.config]
        case .output: return [.schedule]
        }
    }

    var outputPorts: [PortType] {
        switch category {
        case .trigger: return [.trigger]
        case .source: return [.events]
        case .time, .tasks: return [.events]
        case .create: return [.events]
        case .transform: return [.events]
        case .weights, .energy: return [.preferences]
        case .rules: return [.events, .preferences]
        case .condition: return [.events]
        case .social: return [.events, .preferences]
        case .meta: return [.config]
        case .output: return [.schedule]
        }
    }

    /// Check if this node can connect to another.
    func canConnect(to other: ScheduleIntent) -> Bool {
        let myOutputs = Set(outputPorts)
        let theirInputs = Set(other.inputPorts)
        return !myOutputs.isDisjoint(with: theirInputs)
    }
}

// MARK: - 3. Parallel Branches

/// A branch in a parallel split — independent pipeline segments
/// that merge their results.
struct ParallelBranch: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var intents: [ScheduleIntent]
    /// Time filter for this branch (e.g. morning only).
    var timeFilter: Period?

    init(
        id: String = UUID().uuidString,
        name: String,
        intents: [ScheduleIntent],
        timeFilter: Period? = nil
    ) {
        self.id = id
        self.name = name
        self.intents = intents
        self.timeFilter = timeFilter
    }
}

/// A split-merge node in the graph.
/// Events are split into branches, each optimized independently,
/// then results are merged.
struct ParallelSplit: Codable, Hashable, Sendable {
    var branches: [ParallelBranch]
    var mergeStrategy: MergeStrategy

    enum MergeStrategy: String, Codable, Hashable, Sendable {
        /// Concatenate all branch results.
        case concat
        /// Pick the best-scoring branch.
        case bestFitness
        /// Interleave by time (earliest first).
        case byTime
    }

    /// Expand into a flat intent list for compilation.
    /// Each branch becomes a conditional based on its time filter.
    func expand() -> [ScheduleIntent] {
        var result: [ScheduleIntent] = []
        for branch in branches {
            if let period = branch.timeFilter {
                // Branch becomes: prefer this period for these intents
                result.append(.preferPeriod(match: .all, period: period))
            }
            result.append(contentsOf: branch.intents)
        }
        return result
    }
}

// MARK: - 4. Variables

/// A named parameter that can be referenced by multiple nodes.
/// Changing the variable updates all referencing nodes.
struct PipelineVariable: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var type: ValueType
    var defaultValue: PipelineValue

    init(
        id: String = UUID().uuidString,
        name: String,
        type: ValueType,
        defaultValue: PipelineValue
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
    }

    enum ValueType: String, Codable, Hashable, Sendable {
        case int
        case double
        case string
        case period
        case horizon
        case bool
    }
}

/// A concrete value for a pipeline variable.
enum PipelineValue: Codable, Hashable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case period(Period)
    case horizon(Horizon)
    case bool(Bool)

    var asInt: Int? {
        if case .int(let v) = self { return v }
        return nil
    }
    var asDouble: Double? {
        if case .double(let v) = self { return v }
        return nil
    }
    var asString: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var asPeriod: Period? {
        if case .period(let v) = self { return v }
        return nil
    }
}

// MARK: - Variable Substitution on Intents

extension ScheduleIntent {
    /// Apply variable substitutions. Variables are referenced as $name.
    func applyVariables(_ vars: [String: PipelineValue]) -> ScheduleIntent {
        guard !vars.isEmpty else { return self }
        switch self {
        case .focusBlock(let minutes, let period):
            let m = vars["duration"]?.asInt ?? vars["focusDuration"]?.asInt ?? minutes
            let p = vars["period"]?.asPeriod ?? period
            return .focusBlock(minutes: m, period: p)
        case .createBlock(let title, let minutes, let period, let focus):
            let t = vars["title"]?.asString ?? title
            let m = vars["duration"]?.asInt ?? minutes
            let p = vars["period"]?.asPeriod ?? period
            return .createBlock(title: t, minutes: m, period: p, focus: focus)
        case .noEventsBefore(let hour):
            let h = vars["startHour"]?.asInt ?? hour
            return .noEventsBefore(hour: h)
        case .noEventsAfter(let hour):
            let h = vars["endHour"]?.asInt ?? hour
            return .noEventsAfter(hour: h)
        case .maxMeetings(let perDay):
            let n = vars["maxMeetings"]?.asInt ?? perDay
            return .maxMeetings(perDay: n)
        case .breakEvery(let work, let rest):
            let w = vars["workMinutes"]?.asInt ?? work
            let r = vars["breakMinutes"]?.asInt ?? rest
            return .breakEvery(workMinutes: w, breakMinutes: r)
        case .splitLong(let max):
            let m = vars["maxTaskMinutes"]?.asInt ?? max
            return .splitLong(maxMinutes: m)
        case .capTotal(let max):
            let m = vars["maxDailyMinutes"]?.asInt ?? max
            return .capTotal(minutesPerDay: m)
        case .prioritizeDeadlines(let weight):
            let w = vars["deadlineWeight"]?.asDouble ?? weight
            return .prioritizeDeadlines(weight: w)
        case .prioritizeFocus(let weight):
            let w = vars["focusWeight"]?.asDouble ?? weight
            return .prioritizeFocus(weight: w)
        case .horizon:
            if let h = vars["horizon"]?.asString.flatMap({ Horizon(rawValue: $0) }) {
                return .horizon(h)
            }
            return self
        default:
            return self
        }
    }
}

// MARK: - Extended OptimizationRequest

extension OptimizationRequest {

    /// Create a request from a subgraph, expanding it with variable bindings.
    @MainActor static func fromSubgraph(
        _ subgraph: Subgraph,
        registry: SubgraphRegistry,
        variables: [String: PipelineValue] = [:]
    ) -> OptimizationRequest {
        let expanded = subgraph.expand(subgraphs: registry.subgraphs, variables: variables)
        return OptimizationRequest(
            expanded,
            name: subgraph.name,
            description: subgraph.description
        )
    }

    /// Create a request from parallel branches.
    static func fromParallel(_ split: ParallelSplit, name: String? = nil) -> OptimizationRequest {
        OptimizationRequest(
            split.expand(),
            name: name ?? "Parallel: \(split.branches.map(\.name).joined(separator: " + "))"
        )
    }

    /// Subgraph IDs referenced by this request.
    var subgraphIds: [String] {
        intents.compactMap { intent in
            if case .saveAsPreset(let name) = intent { return name }
            return nil
        }
    }
}

// MARK: - IntentGraph Extensions

extension IntentGraph {

    /// Expand subgraph references in the graph.
    /// Any node that references a subgraph is replaced with its contents.
    mutating func expandSubgraphs(subgraphs: [String: Subgraph], variables: [String: PipelineValue] = [:]) {
        // Collect nodes that reference subgraphs
        let subgraphNodes = nodes.values.filter { node in
            if case .saveAsPreset = node.intent { return true }
            return false
        }

        for node in subgraphNodes {
            if case .saveAsPreset(let name) = node.intent,
               let sg = subgraphs.values.first(where: { $0.name == name }) {
                // Remove the reference node
                removeNode(node.intent)
                // Add expanded intents
                let expanded = sg.expand(subgraphs: subgraphs, variables: variables)
                for intent in expanded {
                    addNode(intent)
                }
            }
        }

        // Re-resolve dependencies after expansion
        resolveDependencies()
        detectConflicts()
    }

    /// Validate port compatibility: each edge should connect compatible ports.
    func validatePorts() -> [String] {
        var errors: [String] = []
        for edge in edges where edge.kind == .dependsOn {
            guard let fromNode = nodes[edge.from],
                  let toNode = nodes[edge.to] else { continue }
            if !fromNode.intent.canConnect(to: toNode.intent) {
                errors.append(
                    "\(fromNode.intent.label) cannot feed into \(toNode.intent.label) — incompatible ports"
                )
            }
        }
        return errors
    }
}
