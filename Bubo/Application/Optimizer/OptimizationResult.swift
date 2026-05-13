import Foundation
import BuboOptimizer

// MARK: - Actionable Resolution

/// An actionable resolution generated when a schedule fails.
struct ActionableResolution: Sendable, Identifiable {

    init(
        title: String,
        modifier: OptimizationRequest
    ) {
        self.title = title
        self.modifier = modifier
    }

    let id = UUID()
    let title: String
    let modifier: OptimizationRequest
}

// MARK: - Optimization Result Wrapper

/// Result of running the optimizer through any entry point.
enum OptimizationResult: Sendable {
    case success(OptimizerResult)
    case noEventsToOptimize
    case infeasible(reason: String, snapshot: ScheduleSnapshot? = nil, resolutions: [ActionableResolution] = [])
    case partialSuccess(OptimizerResult, warnings: [String], resolutions: [ActionableResolution] = [])

    var errorMessage: String? {
        switch self {
        case .noEventsToOptimize: return "No events to optimize"
        case .infeasible(let reason, _, _): return reason
        case .partialSuccess(_, let warnings, _): return warnings.first
        case .success: return nil
        }
    }

    var optimizerResult: OptimizerResult? {
        switch self {
        case .success(let r): return r
        case .partialSuccess(let r, _, _): return r
        default: return nil
        }
    }
}

// MARK: - Applied Request Summary (for the Reasoning Surface)

/// Lightweight «what was just applied» record kept on `OptimizerService`
/// for the few seconds after a Run completes. The `SmartActions` row
/// reads this to render its trailing «Done · why?» hint, where tap-on-
/// «why?» reveals which intents the applied request carried.
struct AppliedRequestSummary: Sendable {

    init(
        request: OptimizationRequest,
        label: String,
        appliedAt: Date,
        taskCount: Int,
        scenarioCount: Int,
        appliedScenarioIndex: Int
    ) {
        self.request = request
        self.label = label
        self.appliedAt = appliedAt
        self.taskCount = taskCount
        self.scenarioCount = scenarioCount
        self.appliedScenarioIndex = appliedScenarioIndex
    }

    let request: OptimizationRequest
    let label: String
    let appliedAt: Date
    let taskCount: Int
    let scenarioCount: Int
    let appliedScenarioIndex: Int

    /// Whether this summary is still recent enough to surface in the UI.
    var isFresh: Bool {
        Date().timeIntervalSince(appliedAt) < 8
    }

    /// One-line human-readable summary of what just happened.
    var headline: String {
        switch taskCount {
        case 0:  return label
        case 1:  return "\(label) · 1\u{00A0}task"
        default: return "\(label) · \(taskCount)\u{00A0}tasks"
        }
    }
}
