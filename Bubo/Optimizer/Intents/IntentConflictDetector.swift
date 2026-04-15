import Foundation

// MARK: - Intent Conflict Detector

/// Detects contradictions and warnings in a set of intents.
/// Shown in the intent composer so users see problems before running.
///
/// Types of conflicts:
/// - **Hard conflicts**: contradictory intents (e.g. noEventsBefore(14) + morningPerson)
/// - **Warnings**: redundant or suboptimal combos (e.g. two speed intents)
/// - **Info**: non-obvious interactions worth noting
enum IntentConflictDetector {

    struct Conflict: Identifiable, Sendable {
        let id = UUID()
        let severity: Severity
        let message: String
        let involvedIndices: [Int]  // indices into the intents array
        var resolutions: [ActionableResolution] = []

        enum Severity: Sendable {
            case error    // contradictory — will produce bad results
            case warning  // redundant or suboptimal
            case info     // non-obvious interaction
        }
    }

    /// Analyze a set of intents using the graph backend.
    /// Detects pairwise conflicts from the graph + redundancy from flat analysis.
    static func analyze(_ intents: [ScheduleIntent]) -> [Conflict] {
        var conflicts: [Conflict] = []

        // Build graph to get structural conflicts
        let graph = IntentGraph.build(from: intents)

        // Graph-detected conflicts (pairwise + transitive)
        for (nodeA, nodeB, reason) in graph.conflicts {
            let idxA = intents.firstIndex(of: nodeA.intent)
            let idxB = intents.firstIndex(of: nodeB.intent)
            conflicts.append(Conflict(
                severity: .error,
                message: reason,
                involvedIndices: [idxA, idxB].compactMap { $0 }
            ))
        }

        // Redundancy checks — driven by ScheduleIntent.singleCardinalityKey so
        // the detector and the suggestion composer agree on which families
        // collapse to a single value.
        var byCardinality: [IntentCardinalityKey: [(Int, ScheduleIntent)]] = [:]
        for (i, intent) in intents.enumerated() {
            if let key = intent.singleCardinalityKey {
                byCardinality[key, default: []].append((i, intent))
            }
        }

        for (key, entries) in byCardinality where entries.count > 1 {
            var resolutions: [ActionableResolution] = []
            for (_, intent) in entries {
                resolutions.append(ActionableResolution(
                    title: "Keep '\(intent.label)'",
                    modifier: OptimizationRequest(intent)
                ))
            }
            conflicts.append(Conflict(
                severity: .warning,
                message: "Multiple \(key.rawValue) settings — only the last applies",
                involvedIndices: entries.map(\.0),
                resolutions: resolutions
            ))
        }

        // Creative block size check
        for (i, intent) in intents.enumerated() {
            let neededMinutes: Int
            switch intent {
            case .focusBlock(let m, _): neededMinutes = m
            case .createBlock(_, let m, _, _): neededMinutes = m
            case .pomodoroSession(let p): neededMinutes = p.totalMinutes
            default: continue
            }

            var beforeHour = 0
            var afterHour = 24
            for other in intents {
                if case .noEventsBefore(let h) = other { beforeHour = h }
                if case .noEventsAfter(let h) = other { afterHour = h }
            }
            let windowMinutes = (afterHour - beforeHour) * 60
            if windowMinutes > 0 && neededMinutes > windowMinutes {
                var resolutions: [ActionableResolution] = []
                let requiredHours = Int(ceil(Double(neededMinutes) / 60.0))
                if beforeHour + requiredHours <= 24 {
                    resolutions.append(ActionableResolution(
                        title: "Expand window to \(requiredHours)h",
                        modifier: OptimizationRequest(.workingHours(start: beforeHour, end: beforeHour + requiredHours))
                    ))
                }
                conflicts.append(Conflict(
                    severity: .error,
                    message: "\(neededMinutes)m block won't fit in \(windowMinutes)m window",
                    involvedIndices: [i],
                    resolutions: resolutions
                ))
            }
        }

        // Info: auto-resolved dependencies
        let autoResolved = graph.nodes.values.filter { $0.isAutoResolved }
        for node in autoResolved {
            conflicts.append(Conflict(
                severity: .info,
                message: "\(node.intent.label) auto-added as dependency",
                involvedIndices: []
            ))
        }

        // Info: missing defaults
        let hasHorizon = intents.contains { if case .horizon = $0 { return true }; return false }
        let hasSpeed = intents.contains { if case .speed = $0 { return true }; return false }
        if !hasHorizon {
            conflicts.append(Conflict(severity: .info, message: "Defaults to today", involvedIndices: []))
        }
        if !hasSpeed {
            conflicts.append(Conflict(severity: .info, message: "Using quick mode", involvedIndices: []))
        }

        return conflicts
    }

    /// Quick check: does the intent set have any hard conflicts?
    static func hasErrors(_ intents: [ScheduleIntent]) -> Bool {
        analyze(intents).contains { $0.severity == .error }
    }
}
