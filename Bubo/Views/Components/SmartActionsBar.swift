import SwiftUI

/// Slim main-screen bar that hosts the contextual `SmartActions` row
/// next to a compact «Backlog» entry chip. Replaces the legacy
/// inline-backlog card: capture-first task creation now lives in the
/// fullscreen backlog (one-tap entry on the right), and SmartActions
/// itself stays the single optimizer entry point on the main screen.
///
/// Birman: «один экран — одна работа». The main screen reads the
/// schedule and exposes one verb («what should the optimizer do
/// next?»); typing a brain-dump stays in fullscreen, where it
/// belongs to its own mental model.
struct SmartActionsBar: View {

    let backlogService: BacklogService
    let optimizerService: OptimizerService
    /// Drives the `QuickActionRanker` that powers the top-3 ranked
    /// chips inside the SmartActions calm-state row.
    let reminderService: ReminderService

    /// Schedule the unscheduled backlog onto the calendar.
    let onScheduleBacklog: () async -> Void
    /// Run the deadline-mode preset (urgent items first).
    let onFocusOnDeadlines: () async -> Void
    /// Run an arbitrary `OptimizationRequest` — used by SmartActions
    /// for soft-suggestion Run and the Plan day… popover presets.
    let onRunRequest: (OptimizationRequest, String) async -> Void
    /// Open the command palette (calm-state «More…» / global ⌘K).
    let onOpenPalette: () -> Void
    /// Cycle the just-applied scenario.
    let onSwitchScenario: ((Int) -> Void)?
    /// Bulk-lock today's events — calm popover quick action.
    let onLockTodaysEvents: (() -> Void)?
    /// Open the fullscreen backlog (capture / edit / reorder).
    let onEnterFullscreen: () -> Void

    @Environment(\.activeSkin) private var skin

    private var allActiveTasks: [BacklogTask] {
        BacklogLogic.activeTasks(backlogService.tasks)
    }

    private var pendingWorkloadMinutes: Int {
        allActiveTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Same capacity-section plan SmartActions used to read from the
    /// inline backlog. Orders tasks by storage order and partitions
    /// into fitting / overflowing using the day's remaining minutes.
    private var capacityPlan: BacklogLogic.CapacitySectionPlan {
        BacklogLogic.CapacitySectionPlan(
            orderedTasks: allActiveTasks,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        )
    }

    private var capacityForecast: BacklogLogic.CapacityForecast {
        BacklogLogic.capacityForecast(
            pendingMinutes: pendingWorkloadMinutes,
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )
    }

    /// Minutes left in today's working window, mirroring the inline
    /// backlog's helper. Only counts unscheduled events (ignores
    /// already-placed backlog tasks because their cost is already on
    /// the calendar).
    private var remainingWorkdayMinutes: Int {
        let cal = Calendar.current
        let now = Date()
        let workingHours = optimizerService.workingHours
        guard let dayEnd = cal.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: now) else {
            return 0
        }
        return max(0, Int(dayEnd.timeIntervalSince(now) / 60))
    }

    /// Top-3 context-ranked actions, surfaced inside the calm-state
    /// row of SmartActions. Re-computed on every render — the ranker
    /// is cheap (one walk over today's events) and re-running it
    /// keeps the chip set fresh as the schedule mutates without any
    /// manual invalidation.
    private var rankedCalmActions: [QuickActionRanker.ScoredAction] {
        let ranker = QuickActionRanker(
            backlogService: backlogService,
            reminderService: reminderService,
            intentLearner: optimizerService.intentLearner
        )
        return ranker.rank(limit: 3)
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            SmartActions(
                forecast: capacityForecast,
                overflowingCount: capacityPlan.overflowing.count,
                overflowMinutes: capacityPlan.overflowMinutes,
                overflowHasUrgent: capacityPlan.overflowHasUrgent,
                suggestion: optimizerService.suggestionEngine?.suggestion,
                shadowProposal: optimizerService.shadowProposal,
                recentApplied: optimizerService.lastAppliedRequest,
                onScheduleBacklog: onScheduleBacklog,
                onFocusOnDeadlines: onFocusOnDeadlines,
                onRunRequest: onRunRequest,
                onOpenPalette: onOpenPalette,
                onSwitchScenario: onSwitchScenario,
                onLockTodaysEvents: onLockTodaysEvents,
                compact: true,
                rankedCalmActions: rankedCalmActions
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // Capacity micro-badge — at-a-glance «is today realistic»
            // restored after the inline backlog header (with its
            // capacity ring) was removed. Tints red when the queue
            // exceeds the working window so the alarm is visible
            // even while SmartActions is in calm/soft state.
            if !allActiveTasks.isEmpty {
                capacityBadge
            }

            // Thin trailing chip — the only entry point to the
            // fullscreen backlog now that the inline card is gone.
            // Renders the active-task count as a quiet badge so the
            // user keeps the «how much is in the queue» glance the
            // old header used to provide. Hidden when the queue is
            // empty AND the user has no tombstones to recover —
            // there's nothing to open.
            if shouldShowBacklogEntry {
                backlogEntryChip
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
    }

    private var shouldShowBacklogEntry: Bool {
        !allActiveTasks.isEmpty
            || !BacklogLogic.completedToday(backlogService.tasks).isEmpty
            || !backlogService.frozen.isEmpty
    }

    /// True when today's queue exceeds the working window —
    /// `.over` or `.afterHours`. Drives the red tint on the badge.
    private var capacityIsOver: Bool {
        switch capacityForecast {
        case .fits:                   return false
        case .over, .afterHours:      return true
        }
    }

    /// Compact «Xh queued» indicator. Red tint when the forecast
    /// reports overflow / after-hours so the alarm is visible at a
    /// glance even when SmartActions is in calm/soft state. Tooltip
    /// breaks down the full picture (queued vs remaining workday).
    @ViewBuilder
    private var capacityBadge: some View {
        let isOver = capacityIsOver
        let label = DS.formatMinutes(pendingWorkloadMinutes)
        let tint: Color = isOver ? skin.resolvedDestructiveColor : skin.resolvedTextTertiary
        HStack(spacing: 2) {
            Image(systemName: isOver ? "exclamationmark.triangle.fill" : "tray.fill")
                .font(.caption2)
            Text(label)
                .font(DS.Typography.machineHint)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .help(capacityTooltip)
        .accessibilityLabel("\(label) of work queued. \(capacityTooltip)")
    }

    private var capacityTooltip: String {
        let queued = DS.formatMinutes(pendingWorkloadMinutes)
        let remaining = DS.formatMinutes(remainingWorkdayMinutes)
        switch capacityForecast {
        case .fits:        return "\(queued) queued · \(remaining) left today"
        case .over:        return "\(queued) queued · over today's window"
        case .afterHours:  return "\(queued) queued · runs past working hours"
        }
    }

    @ViewBuilder
    private var backlogEntryChip: some View {
        Button {
            Haptics.tap()
            onEnterFullscreen()
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: "tray.full")
                    .font(.footnote)
                Text("Backlog")
                    .font(.footnote.weight(.medium))
                if !allActiveTasks.isEmpty {
                    Text("\(allActiveTasks.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
            .foregroundStyle(skin.resolvedTextSecondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.accentColor.opacity(DS.Opacity.borderIdle),
                    lineWidth: DS.Border.thin
                )
            )
        }
        .buttonStyle(.plain)
        .help("Open the fullscreen backlog — type a new task, edit, or reorder")
    }
}
