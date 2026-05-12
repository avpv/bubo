import SwiftUI
import BuboDomain

/// Single contextual row directly under the fullscreen header — same
/// `SmartActions` component the inline `BacklogView` mounts in the same
/// position. Replaces the mid-list `SpillOverMarker` so the action
/// attaches to the diagnosis (header) rather than the tail of the
/// evidence (list).
///
/// Owns the small amount of derived computation (capacity plan +
/// forecast) that gates which `SmartActions` chips render. Everything
/// callback-shaped is forwarded to the host so the optimizer wiring
/// stays in one place.
struct BacklogSmartActionsRow: View {
    let activeTasks: [BacklogTask]
    let remainingWorkdayMinutes: Int
    let pendingWorkloadMinutes: Int
    let optimizerService: OptimizerService
    /// Soft suggestion to surface inside `SmartActions`; nil when the
    /// host has already promoted it to a 2-line banner above (so the
    /// chip and the banner don't compete for the same attention).
    let activeBacklogSuggestion: SuggestionEngine.Suggestion?

    var onScheduleBacklog: (() async -> Void)? = nil
    var onFocusOnDeadlines: (() async -> Void)? = nil
    var onRunRequest: ((OptimizationRequest, String) async -> Void)? = nil
    var onOpenPalette: (() -> Void)? = nil
    var onSwitchScenario: ((Int) -> Void)? = nil
    var onLockTodaysEvents: (() -> Void)? = nil

    var body: some View {
        let plan = BacklogLogic.CapacitySectionPlan(
            orderedTasks: activeTasks,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        )
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: pendingWorkloadMinutes,
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )

        SmartActions(
            forecast: forecast,
            overflowingCount: plan.overflowing.count,
            overflowMinutes: plan.overflowMinutes,
            overflowHasUrgent: plan.overflowHasUrgent,
            // Suppress the soft-suggestion chip here when the backlog
            // surfaces the same suggestion as a 2-line banner above —
            // the banner is the primary affordance for that signal.
            // Hard-state chips (Schedule overflow / Pack urgent first)
            // remain because they ride the forecast, not the soft
            // suggestion stream.
            suggestion: activeBacklogSuggestion == nil
                ? optimizerService.suggestionEngine?.suggestion
                : nil,
            shadowProposal: optimizerService.shadowProposal,
            recentApplied: optimizerService.lastAppliedRequest,
            onScheduleBacklog: { await onScheduleBacklog?() },
            onFocusOnDeadlines: { await onFocusOnDeadlines?() },
            onRunRequest: { request, label in
                await onRunRequest?(request, label)
            },
            onOpenPalette: { onOpenPalette?() },
            onSwitchScenario: onSwitchScenario,
            onLockTodaysEvents: onLockTodaysEvents
        )
        .padding(.horizontal, DS.Spacing.sm)
        // Vertical air on both sides so the diagnosis row sits as its
        // own beat between the header above and the filter band below.
        // Without it the «Pack urgent tasks first» / «Schedule overflow»
        // message visually fuses with the smart-filter chips.
        // PRINCIPLES.md §2 — rhythm via whitespace, not chrome.
        .padding(.vertical, DS.Spacing.xs)
    }
}
