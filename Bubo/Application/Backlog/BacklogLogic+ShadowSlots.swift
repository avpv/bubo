import Foundation
import BuboDomain
import BuboOptimizer

// MARK: - BacklogLogic.proposedSlotsFromShadow
//
// Lives in `Application/Backlog/` rather than `Domain/` because the input
// parameter (`ScheduleScenario`) is an `Optimizer/` type and Domain must
// not depend on Optimizer. The call site (`BacklogFullscreenView`) is
// unchanged — `BacklogLogic.proposedSlotsFromShadow(...)` still resolves
// to this extension method via Swift's module-level extension dispatch.

extension BacklogLogic {
    /// Per-task proposed slot map sourced from the optimizer's shadow
    /// proposal. Walks the scenario's active genes and pulls out
    /// `(taskId → startTime)` entries for any gene whose `reservedTaskIds`
    /// includes a backlog task. Returns an empty dict if the scenario
    /// is nil or carries no task-bearing genes — caller falls back to
    /// `naiveProposedSlots`.
    ///
    /// Birman: «let the machine sweat» — once the shadow optimizer is
    /// running in the background, every overflow row's `→ HH:MM`
    /// reflects what the GA would actually do, not a greedy stub.
    public static func proposedSlotsFromShadow(
        _ scenario: ScheduleScenario?
    ) -> [String: Date] {
        guard let scenario else { return [:] }
        var result: [String: Date] = [:]
        for gene in scenario.activeGenes {
            for taskId in gene.reservedTaskIds {
                // First gene wins — backlog tasks usually map to one
                // gene each, but a long task split across pomodoro
                // chunks would have multiple. The first gene's start
                // time is the earliest occurrence, which is what the
                // user wants to see.
                if result[taskId] == nil {
                    result[taskId] = gene.startTime
                }
            }
        }
        return result
    }
}
