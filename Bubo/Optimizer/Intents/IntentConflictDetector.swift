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

        enum Severity: Sendable {
            case error    // contradictory — will produce bad results
            case warning  // redundant or suboptimal
            case info     // non-obvious interaction
        }
    }

    /// Analyze a set of intents and return all detected conflicts.
    static func analyze(_ intents: [ScheduleIntent]) -> [Conflict] {
        var conflicts: [Conflict] = []

        // Index intents by type for efficient lookup
        var timeConstraints: [(Int, ScheduleIntent)] = []
        var speedIntents: [(Int, ScheduleIntent)] = []
        var horizonIntents: [(Int, ScheduleIntent)] = []
        var stabilityIntents: [(Int, ScheduleIntent)] = []
        var energyIntents: [(Int, ScheduleIntent)] = []
        var hasBacklog = false
        var hasBacklogSlots = false
        var hasMorningPerson = false
        var morningPersonIndex = -1
        var hasLowEnergy = false
        var lowEnergyIndex = -1
        var noEventsBefore: (Int, Int)? = nil  // (index, hour)
        var noEventsAfter: (Int, Int)? = nil
        var creativeIntents: [(Int, ScheduleIntent)] = []

        for (i, intent) in intents.enumerated() {
            switch intent {
            case .noEventsBefore(let h):
                timeConstraints.append((i, intent))
                noEventsBefore = (i, h)
            case .noEventsAfter(let h):
                timeConstraints.append((i, intent))
                noEventsAfter = (i, h)
            case .speed:
                speedIntents.append((i, intent))
            case .horizon:
                horizonIntents.append((i, intent))
            case .stability:
                stabilityIntents.append((i, intent))
            case .morningPerson:
                hasMorningPerson = true
                morningPersonIndex = i
                energyIntents.append((i, intent))
            case .lowEnergy:
                hasLowEnergy = true
                lowEnergyIndex = i
                energyIntents.append((i, intent))
            case .peakEnergy:
                energyIntents.append((i, intent))
            case .includeBacklog:
                hasBacklog = true
            case .findSlotsForBacklog:
                hasBacklogSlots = true
            case .focusBlock, .createBlock, .pomodoroSession:
                creativeIntents.append((i, intent))
            default: break
            }
        }

        // MARK: - Hard Conflicts

        // noEventsBefore(14) + morningPerson → morning blocked
        if let (beforeIdx, beforeHour) = noEventsBefore, hasMorningPerson && beforeHour >= 11 {
            conflicts.append(Conflict(
                severity: .error,
                message: "Morning blocked until \(beforeHour):00 but morning-heavy schedule requested",
                involvedIndices: [beforeIdx, morningPersonIndex]
            ))
        }

        // noEventsAfter too early + creative blocks that won't fit
        if let (afterIdx, afterHour) = noEventsAfter, let (beforeIdx, beforeHour) = noEventsBefore {
            let window = afterHour - beforeHour
            if window < 2 {
                conflicts.append(Conflict(
                    severity: .error,
                    message: "Working window is only \(window)h (\(beforeHour):00–\(afterHour):00) — too short",
                    involvedIndices: [beforeIdx, afterIdx]
                ))
            }
        }

        // Creative intents without a time window
        for (creativeIdx, creative) in creativeIntents {
            if let (_, afterHour) = noEventsAfter, let (_, beforeHour) = noEventsBefore {
                let windowMinutes = (afterHour - beforeHour) * 60
                let neededMinutes: Int
                switch creative {
                case .focusBlock(let m, _): neededMinutes = m
                case .createBlock(_, let m, _, _): neededMinutes = m
                case .pomodoroSession(let p): neededMinutes = p.totalMinutes
                default: neededMinutes = 0
                }
                if neededMinutes > windowMinutes {
                    conflicts.append(Conflict(
                        severity: .error,
                        message: "\(neededMinutes)m block won't fit in \(windowMinutes)m window",
                        involvedIndices: [creativeIdx]
                    ))
                }
            }
        }

        // MARK: - Warnings (Redundancy)

        // Duplicate speed intents
        if speedIntents.count > 1 {
            conflicts.append(Conflict(
                severity: .warning,
                message: "Multiple speed settings — only the last one applies",
                involvedIndices: speedIntents.map(\.0)
            ))
        }

        // Duplicate horizon intents
        if horizonIntents.count > 1 {
            conflicts.append(Conflict(
                severity: .warning,
                message: "Multiple time horizons — only the last one applies",
                involvedIndices: horizonIntents.map(\.0)
            ))
        }

        // Duplicate stability intents
        if stabilityIntents.count > 1 {
            conflicts.append(Conflict(
                severity: .warning,
                message: "Multiple stability settings — only the last one applies",
                involvedIndices: stabilityIntents.map(\.0)
            ))
        }

        // includeBacklog + findSlotsForBacklog (redundant)
        if hasBacklog && hasBacklogSlots {
            conflicts.append(Conflict(
                severity: .info,
                message: "findSlotsForBacklog already includes backlog tasks",
                involvedIndices: []
            ))
        }

        // lowEnergy + prioritizeFocus with high weight → tension
        if hasLowEnergy {
            for (i, intent) in intents.enumerated() {
                if case .prioritizeFocus(let w) = intent, w > 1.5 {
                    conflicts.append(Conflict(
                        severity: .warning,
                        message: "Low energy mode conflicts with aggressive focus prioritization",
                        involvedIndices: [lowEnergyIndex, i]
                    ))
                }
            }
        }

        // MARK: - Info

        // Creative intent without horizon → defaults to today
        if !creativeIntents.isEmpty && horizonIntents.isEmpty {
            conflicts.append(Conflict(
                severity: .info,
                message: "No horizon set — will optimize for today",
                involvedIndices: []
            ))
        }

        // No speed set → defaults to quick
        if speedIntents.isEmpty {
            conflicts.append(Conflict(
                severity: .info,
                message: "No speed set — using quick mode",
                involvedIndices: []
            ))
        }

        return conflicts
    }

    /// Quick check: does the intent set have any hard conflicts?
    static func hasErrors(_ intents: [ScheduleIntent]) -> Bool {
        analyze(intents).contains { $0.severity == .error }
    }
}
