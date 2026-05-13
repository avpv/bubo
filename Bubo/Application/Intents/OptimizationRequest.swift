import Foundation
import BuboDomain
import BuboOptimizer

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
