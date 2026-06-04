import SwiftUI
import BuboDomain

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

    /// The single best context-ranked action, surfaced inside the
    /// calm-state row of SmartActions. Reduced from top-3 to top-1: a
    /// wall of competing suggestion chips above the day was the main
    /// source of overload — show the one best verb here, the rest live
    /// behind «More» (⌘K). Re-computed on every render (the ranker is a
    /// cheap single walk over today's events).
    private var rankedCalmActions: [QuickActionRanker.ScoredAction] {
        let ranker = QuickActionRanker(
            backlogService: backlogService,
            reminderService: reminderService,
            intentLearner: optimizerService.intentLearner
        )
        return ranker.rank(limit: 1)
    }

    var body: some View {
        // All chips — the diagnosis/treatment row from SmartActions plus
        // the trailing capacity / free-time / Backlog badges — live in
        // one wrapping `ChipRow` (FlowLayout) inside SmartActions itself.
        // Two siblings inside an outer HStack used to compete for width:
        // a long soft-state chip would overflow its share and bleed over
        // the badges, producing the visible «5 tasks to schedule · 10 h
        // 45 min free · Backlog 5 · Org…» smear. With every chip in one
        // FlowLayout, the row simply wraps to the next line when the
        // popover is too narrow — no overlap, no clipping.
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
            rankedCalmActions: rankedCalmActions,
            trailing: AnyView(trailingBadges)
        )
    }

    /// Trailing chip after SmartActions' primary/ranked/More chips —
    /// only the interactive Backlog quick-capture entry.
    ///
    /// The old capacity («3 h queued») and free-time («4 h free») badges
    /// were removed from this rail: they were non-interactive chips
    /// (`allowsHitTesting(false)`) that *looked* tappable, and both
    /// numbers are already shown where they belong — free time on the
    /// timeline's free-slot rows, queued workload in the backlog. Pulling
    /// them out of the action rail is the single biggest declutter of the
    /// top bar (status stops masquerading as actions).
    @ViewBuilder
    private var trailingBadges: some View {
        if shouldShowBacklogEntry {
            backlogEntryChip
        }
    }

    private var shouldShowBacklogEntry: Bool {
        !allActiveTasks.isEmpty
            || !BacklogLogic.completedToday(backlogService.tasks).isEmpty
            || !backlogService.frozen.isEmpty
    }

    @ViewBuilder
    private var backlogEntryChip: some View {
        ChipButton(
            variant: .quiet,
            icon: "tray.full",
            title: "Backlog",
            trailingBadge: allActiveTasks.isEmpty ? nil : "\(allActiveTasks.count)"
        ) {
            Haptics.tap()
            captureTitle = ""
            captureBinding.wrappedValue = true
        }
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
                .font(DS.Typography.body(skin: skin))
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
