import Foundation
import Observation

// MARK: - OptimizerService shadow-proposal pre-compute and scenario switching
//
// `shadowProposal` is a background pre-computed alternative scenario the
// UI offers as a "what-if" overlay without committing it. This extension
// owns the pre-compute task lifecycle and the post-apply scenario-switch
// path. Extracted from `OptimizerService.swift` so the main file stays
// focused on the request-execute / apply cycle.

extension OptimizerService {

    // MARK: - Shadow proposal (background pre-compute)

    /// Run an `OptimizationRequest` in the background and stash the
    /// best scenario into `shadowProposal` without applying it. Cancels
    /// any previously-pending preview, so callers can fire-and-forget on
    /// every backlog edit without a debouncer (the GA itself absorbs
    /// the cost via internal early-out heuristics on identical input).
    ///
    /// The compute runs through the same `IntentCompiler` path as
    /// `executeRequest`, so locks, exclusions, working-hours and every
    /// other persistent setting apply identically. Only the result
    /// path differs — instead of writing to `scenarios` and flipping
    /// `lastOptimizationDate`, it writes to `shadowProposal` and
    /// `shadowProposalUpdatedAt` and never touches `lastSnapshot` /
    /// `lastAppliedRequest` (those drive undo + the reasoning surface,
    /// neither of which a background preview should perturb).
    ///
    /// Use sparingly — the full GA path is not free. Callers should
    /// debounce upstream (e.g. on a 600 ms timer past the last backlog
    /// keystroke). The simple implementation here is a fire-and-cancel
    /// queue: a fresh call cancels the previous task, so back-to-back
    /// calls collapse to one run on the latest input.
    ///
    /// Birman: «let the machine sweat» — the optimizer is always one beat
    /// ahead, so when the user *does* hit Run it confirms what's already
    /// visible rather than waiting for fresh thinking.
    func previewRequest(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) {
        // Cancel any pending preview so the queue depth stays at 1.
        // Last-writer-wins is the right semantics for a UI-driven
        // pre-compute — earlier inputs are stale by the time a new one
        // lands.
        shadowProposalTask?.cancel()

        guard let backlogSvc = backlogService else { return }

        // Inject the same persistent constraints `executeRequest` adds —
        // a preview that ignores user locks would propose moves the
        // real run won't make, defeating the whole «accurate ghost»
        // purpose.
        var effectiveRequest = request
        if !lockedEventIds.isEmpty {
            effectiveRequest.add(.keepFixed(eventIds: Array(lockedEventIds)))
        }
        if !excludedEventIds.isEmpty {
            effectiveRequest.add(.exclude(eventIds: Array(excludedEventIds)))
        }

        let captured = effectiveRequest
        shadowProposalTask = Task { [weak self] in
            guard let self else { return }
            var compiler = IntentCompiler(
                optimizer: self.optimizer,
                reminderService: reminderService,
                backlogService: backlogSvc
            )
            compiler.subgraphRegistry = self.subgraphRegistry
            compiler.energyCheckInService = self.energyCheckInService
            compiler.pomodoroHistory = self.pomodoroHistory
            let result = await compiler.execute(captured, defaultWorkingHours: self.workingHours)

            // Preview ran during a Task; drop the result if cancelled
            // (a newer preview is already in flight or the caller went
            // away). MainActor hop because `shadowProposal` is on a
            // @MainActor service.
            if Task.isCancelled { return }
            await MainActor.run {
                switch result {
                case .success(let opt), .partialSuccess(let opt, _, _):
                    self.shadowProposal = opt.scenarios.first
                case .noEventsToOptimize, .infeasible:
                    self.shadowProposal = nil
                }
                self.shadowProposalUpdatedAt = Date()
            }
        }
    }

    /// Drop the current shadow proposal — used when the user starts
    /// editing in a way that invalidates it (e.g. major backlog
    /// reorder). Cheap; the preview will re-fill on the next call.
    func clearShadowProposal() {
        shadowProposalTask?.cancel()
        shadowProposalTask = nil
        shadowProposal = nil
        shadowProposalUpdatedAt = nil
    }

    // MARK: - Scenario switching (post-apply)

    /// Swap the currently-applied scenario for a different one in the
    /// same `scenarios` array, without losing the array (and without
    /// the user having to undo + re-run from scratch). Used by
    /// `SmartActions`'s reasoning-row scenario cycle: the GA returned
    /// 2-3 alternatives, the user wants to flip between them.
    ///
    /// Implementation rolls back the previously-applied scenario the
    /// same way `undoLast` does (delete created events, restore
    /// `previousGenes`, unschedule linked backlog rows), then applies
    /// the new scenario through the regular `applyScenario(at:to:)`
    /// path. The new run captures its own `lastSnapshot` whose
    /// `previousGenes` matches the *original* baseline — so a single
    /// undo from this state still rolls all the way back to before any
    /// scenario was applied, regardless of how many times the user
    /// cycled.
    ///
    /// Returns true on success, false when the inputs are out of
    /// bounds or no snapshot exists to roll back from.
    @discardableResult
    func switchToAppliedScenario(
        at index: Int,
        to reminderService: ReminderService
    ) -> Bool {
        guard let snapshot = lastSnapshot else { return false }
        guard index >= 0, index < scenarios.count else { return false }
        guard index != selectedScenarioIndex else { return true }

        // Roll back the existing apply. Identical surface area to
        // `undoLast` minus the state-clearing — we want to preserve
        // `scenarios` and `activeRequest` so the second `applyScenario`
        // below has the context it needs.
        for eventId in snapshot.createdEventIds {
            reminderService.removeLocalEvent(id: eventId)
        }
        for gene in snapshot.appliedGenes {
            backlogService?.unschedule(id: gene.eventId)
        }
        optimizer.currentSchedule = snapshot.previousGenes

        // Snapshot the scenarios array because `applyScenario` would
        // otherwise overwrite `previousGenes` with the just-restored
        // state — which we want — but downstream observers might race.
        let preservedScenarios = scenarios
        applyScenario(at: index, to: reminderService)
        if scenarios.isEmpty {
            scenarios = preservedScenarios
        }

        return true
    }

}
