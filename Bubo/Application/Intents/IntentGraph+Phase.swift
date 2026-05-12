import Foundation

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
