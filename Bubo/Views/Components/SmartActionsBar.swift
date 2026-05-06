import SwiftUI

/// Slim main-screen bar that hosts the contextual `SmartActions` row
/// next to a compact «Backlog» entry chip. Replaces the legacy
/// inline-backlog card: capture-first task creation now lives in the
/// fullscreen backlog (one-tap entry on the right), and SmartActions
/// itself stays the single optimizer entry point on the main screen.
///
/// Birman: «one screen — one job». The main screen reads the
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
    /// Surface an undo toast for the just-captured task. Same shape
    /// the legacy inline backlog used.
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil
    /// External trigger for the quick-capture popover. Bound to
    /// MenuBarView's ⇧⌘N shortcut so the keyboard path opens the
    /// inline capture surface instead of jumping into fullscreen.
    /// Local state (`showingCapture`) drives the actual popover —
    /// this binding flips the same flag from outside.
    var quickCapturePresented: Binding<Bool>? = nil

    @Environment(\.activeSkin) private var skin
    @State private var showingCapture: Bool = false
    @State private var captureTitle: String = ""
    @FocusState private var captureInputFocused: Bool

    /// Effective binding: external trigger when wired, otherwise the
    /// local state. Lets the chip click toggle without involving the
    /// host while still letting ⇧⌘N flip it from outside.
    private var captureBinding: Binding<Bool> {
        quickCapturePresented ?? Binding(get: { showingCapture }, set: { showingCapture = $0 })
    }

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
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
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
            captureTitle = ""
            captureBinding.wrappedValue = true
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: "tray.full")
                    .font(.footnote)
                Text("Backlog")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if !allActiveTasks.isEmpty {
                    Text("\(allActiveTasks.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
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
        .contextMenu {
            Button {
                Haptics.tap()
                onEnterFullscreen()
            } label: {
                Label("Open in fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Quick-capture a task. Right-click for fullscreen.")
        .popover(isPresented: captureBinding, arrowEdge: .top) {
            quickCapturePopover
        }
    }

    /// Inline one-input popover for capture-first task creation.
    /// Mirrors the legacy `addTaskField` of the inline backlog —
    /// type → Return → task lands in the backlog with an undo
    /// toast. Fullscreen escape lives at the bottom for users who
    /// want richer editing.
    @ViewBuilder
    private var quickCapturePopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            TextField("Add a task\u{2026}", text: $captureTitle)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($captureInputFocused)
                .onSubmit(submitCapture)
                .padding(.vertical, DS.Spacing.xxs)

            Text("Tip · type «Prepare report 45m» to set duration inline.")
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)
                .lineLimit(2)

            SkinSeparator()

            Button {
                Haptics.tap()
                captureBinding.wrappedValue = false
                onEnterFullscreen()
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                    Text("Open in fullscreen")
                        .font(.footnote)
                    Spacer()
                }
                .foregroundStyle(skin.resolvedTextSecondary)
                .contentShape(Rectangle())
                .padding(.vertical, DS.Spacing.xs)
            }
            .buttonStyle(.plain)
            .help("Open the fullscreen backlog for editing, reordering, or filters")
        }
        .padding(DS.Spacing.md)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        .onAppear { captureInputFocused = true }
        .background(
            Button("", action: { captureBinding.wrappedValue = false })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private func submitCapture() {
        let parsed = BacklogTitleParser.parse(captureTitle)
        let title = parsed.cleaned
        guard !title.isEmpty else { return }
        // Duration priority: explicit «… 45m» → verb-guess table →
        // user's default. Same precedence the legacy add-task field
        // used so muscle memory carries.
        let duration = parsed.durationMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
            ?? optimizerService.defaultTaskDurationMinutes
        let task = BacklogTask(
            title: title,
            durationMinutes: duration,
            priority: .medium
        )
        backlogService.addTask(task)
        let snapshot = task
        onUndoableAction?("Added \u{201C}\(title)\u{201D}") { [backlogService] in
            _ = backlogService.removeTask(id: snapshot.id)
        }
        captureTitle = ""
        captureBinding.wrappedValue = false
    }
}
