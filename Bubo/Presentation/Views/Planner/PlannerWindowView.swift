import SwiftUI
import BuboDomain

// MARK: - Planner window
//
// UX_WORKFLOW.md stage 1: the «one screen Today» surface. Tasks on the
// left, the day's timeline (events + free slots) on the right, and the
// whole planning loop happens here with direct manipulation:
//
//   drag a task onto a slot            → scheduled into that slot
//   click a task's schedule affordance → first slot that fits
//   type in the capture field          → lands in the backlog
//
// Composition only: state and verbs live on the two screen models the
// UI refactor produced (`BacklogScreenModel`, `MenuBarScreenModel`);
// rows are the same refactored components the popover uses, fed by
// facts + environment actions.

struct PlannerWindowView: View {

    private let settings: ReminderSettings
    private let reminderService: ReminderService
    private let optimizerService: OptimizerService
    private let backlogService: BacklogService

    @State private var backlog: BacklogScreenModel
    @State private var timeline: MenuBarScreenModel
    @State private var toastState = ToastState()
    /// True while a GA rebuild preset is in flight — gates the preset
    /// chips so a double-tap doesn't queue two runs.
    @State private var isRebuilding = false

    @FocusState private var isCaptureFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared minute tick for the «happening now» highlight and header
    /// strings — same pattern as the popover.
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(
        settings: ReminderSettings,
        reminderService: ReminderService,
        optimizerService: OptimizerService,
        backlogService: BacklogService
    ) {
        self.settings = settings
        self.reminderService = reminderService
        self.optimizerService = optimizerService
        self.backlogService = backlogService

        let coordinator = BacklogInteractionCoordinator()
        _timeline = State(initialValue: MenuBarScreenModel(
            reminderService: reminderService,
            optimizerService: optimizerService,
            settings: settings,
            backlogCoordinator: coordinator
        ))
        _backlog = State(initialValue: BacklogScreenModel(
            backlogService: backlogService,
            optimizerService: optimizerService,
            settings: settings
        ))
    }

    private var activeSkin: SkinDefinition { settings.selectedSkin }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                tasksColumn
                    .frame(width: 320)
                Divider()
                dayColumn
                    .frame(maxWidth: .infinity)
            }
            ToastOverlay(toastState: toastState)
        }
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)
        .environment(\.activeSkin, activeSkin)
        .environment(\.backlogRowActions, rowActions)
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(minuteTimer) { timeline.nowTick = $0 }
        .onAppear {
            backlog.reduceMotion = reduceMotion
            backlog.onUndoable = { message, undo in
                toastState.showSuccess(message, icon: "arrow.uturn.backward", onUndo: undo)
            }
        }
        .onChange(of: reduceMotion) { _, newValue in
            backlog.reduceMotion = newValue
        }
        .onChange(of: backlog.newTaskTitle) { _, newValue in
            backlog.parsedNewTaskTitle = BacklogTitleParser.parse(newValue)
        }
    }

    // MARK: - Tasks column

    private var tasksColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                SectionLabel(text: "Tasks")
                Text("\(backlog.activeTasks.count)")
                    .font(DS.Typography.metric(skin: activeSkin))
                    .foregroundStyle(activeSkin.resolvedTextSecondary)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.sm)

            if backlog.visibleTasks.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2.weight(.light))
                        .foregroundStyle(activeSkin.resolvedTextTertiary)
                    Text("Backlog is empty")
                        .font(.subheadline)
                        .foregroundStyle(activeSkin.resolvedTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(backlog.visibleTasks) { task in
                            BacklogTaskRow(
                                task: task,
                                isUrgent: BacklogLogic.isUrgent(task),
                                canMoveUp: backlog.canMoveUp(task),
                                canMoveDown: backlog.canMoveDown(task),
                                defaultTaskDurationMinutes: optimizerService.defaultTaskDurationMinutes
                            )
                        }
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                }
            }

            BacklogAddTaskField(
                newTaskTitle: $backlog.newTaskTitle,
                parsedNewTaskTitle: $backlog.parsedNewTaskTitle,
                isInputFocused: $isCaptureFocused,
                activeTasksIsEmpty: backlog.activeTasks.isEmpty,
                canCreateWithDetails: false,
                onSubmit: { backlog.addTask() },
                onShiftSubmit: { backlog.addTask() }
            )
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.md)
        }
    }

    /// Verbs for the task rows — model mutations plus the planner's
    /// signature verb: «Find a slot now» schedules into the first free
    /// slot today that fits, no aiming required.
    private var rowActions: BacklogRowActions {
        BacklogRowActions(
            complete: { backlog.complete($0) },
            delete: { backlog.delete($0) },
            freeze: { backlog.freeze($0) },
            reorderDrop: { dropped, target in
                backlog.handleReorderDrop(dropped: dropped, target: target)
            },
            moveUp: { backlog.moveTask($0, by: -1) },
            moveDown: { backlog.moveTask($0, by: +1) },
            moveToTop: { backlog.moveTaskToEdge($0, toTop: true) },
            moveToBottom: { backlog.moveTaskToEdge($0, toTop: false) },
            findSlot: { scheduleIntoFirstFit($0) },
            snooze: { task, days in backlog.snoozeDeadline(task, byDays: days) },
            toggleUrgent: { backlog.toggleUrgent($0) }
        )
    }

    // MARK: - Day column

    private var dayColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeline.headerTitle)
                        .font(DS.Typography.headline(skin: activeSkin))
                        .foregroundStyle(activeSkin.resolvedTextPrimary)
                    if !timeline.headerSubtitle.isEmpty {
                        Text(timeline.headerSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(activeSkin.resolvedTextSecondary)
                    }
                }

                Spacer(minLength: DS.Spacing.md)

                // GA rebuild presets — «пересобрать план целиком» happens
                // on the same screen where the result lands: the right
                // column re-renders the new schedule the moment the run
                // applies. Undo lives in the toast.
                HStack(spacing: DS.Spacing.xs) {
                    ChipButton(
                        variant: .prominent,
                        icon: "wand.and.stars",
                        title: "Organize today"
                    ) {
                        runPreset(.organizeDay, label: "Organized today")
                    }
                    .help("Let the optimizer rebuild today around your meetings and tasks")

                    ChipButton(
                        variant: .quiet,
                        icon: "calendar",
                        title: "Plan week"
                    ) {
                        runPreset(.planWeek, label: "Planned the week")
                    }
                    .help("Rebuild the whole week's plan")
                }
                .opacity(isRebuilding ? 0.5 : 1)
                .disabled(isRebuilding)
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    // Today + tomorrow: enough horizon to plan «today and
                    // spill into tomorrow morning» without the window
                    // becoming a week view.
                    ForEach(timeline.timelineDays().prefix(2), id: \.date) { day in
                        DaySectionHeader(
                            date: day.date,
                            count: timeline.visibleEventCount(for: day.events),
                            meta: timeline.dayHeaderMeta(for: day.events, on: day.date),
                            workingHours: optimizerService.workingHours
                        )

                        ForEach(day.items, id: \.id) { item in
                            switch item {
                            case .event(let event):
                                EventRowView(
                                    event: event,
                                    reminderService: reminderService,
                                    isHappeningNow: timeline.nowTick >= event.startDate
                                        && timeline.nowTick < event.endDate
                                )
                            case .slot(let start, let end):
                                PlannerSlotRow(start: start, end: end) { drag in
                                    schedule(dragged: drag, slotStart: start, slotEnd: end)
                                }
                            case .ghost:
                                EmptyView()
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
            }
        }
    }

    // MARK: - Scheduling

    /// Run a GA preset and apply its top scenario — mirrors the
    /// popover's `runQuickAction` contract (apply → toast with undo →
    /// suggestion refresh). The result is visible immediately in the
    /// day column; no navigation, no palette round-trip.
    private func runPreset(_ request: OptimizationRequest, label: String) {
        guard !isRebuilding else { return }
        Haptics.tap()
        isRebuilding = true
        Task { @MainActor in
            defer { isRebuilding = false }
            let result = await optimizerService.executeRequest(request, reminderService: reminderService)
            if case .success = result, !optimizerService.scenarios.isEmpty {
                optimizerService.applyScenario(at: 0, to: reminderService)
                toastState.showSuccess(label, icon: "sparkles") {
                    optimizerService.undoLast(reminderService: reminderService)
                }
                optimizerService.suggestionEngine?.evaluate()
            } else if let error = result.errorMessage {
                toastState.showInfo(error, icon: "exclamationmark.triangle")
            }
        }
    }

    private func schedule(dragged drag: BacklogTaskDrag, slotStart: Date, slotEnd: Date) {
        guard let task = backlogService.tasks.first(where: { $0.id == drag.taskId }) else { return }
        schedule(task, slotStart: slotStart, slotEnd: slotEnd)
    }

    /// The planner's one-click verb: place the task into the first free
    /// slot today (or tomorrow) that fits its duration.
    private func scheduleIntoFirstFit(_ task: BacklogTask) {
        let needed = TimeInterval(task.durationMinutes * 60)
        for day in timeline.timelineDays().prefix(2) {
            for item in day.items {
                if case .slot(let start, let end) = item,
                   end.timeIntervalSince(start) >= needed,
                   start > Date() || end.timeIntervalSince(Date()) >= needed {
                    let effectiveStart = max(start, Date())
                    schedule(task, slotStart: effectiveStart, slotEnd: end)
                    return
                }
            }
        }
        toastState.showInfo("No free slot fits \(DS.formatMinutes(task.durationMinutes))", icon: "calendar.badge.exclamationmark")
    }

    /// Place a backlog task on the calendar at the given slot — same
    /// contract as the popover's `scheduleBacklogTask` (event creation,
    /// `markScheduled`, orphan-chunk cleanup, undo toast).
    /// TODO(UX_WORKFLOW stage 2): extract the shared body into a
    /// `SchedulePlacementService` so the popover and the planner stop
    /// duplicating it.
    private func schedule(_ task: BacklogTask, slotStart: Date, slotEnd: Date) {
        let taskSnapshot = task

        let duration = min(
            TimeInterval(task.durationMinutes * 60),
            slotEnd.timeIntervalSince(slotStart)
        )
        let eventId = "task-\(task.id)"
        let event = CalendarEvent(
            id: eventId,
            title: task.title,
            startDate: slotStart,
            endDate: slotStart.addingTimeInterval(duration),
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard,
            colorTag: .green
        )
        for eid in task.scheduledEventIds where eid != eventId {
            reminderService.removeLocalEvent(id: eid)
        }
        reminderService.addLocalEvent(event)
        backlogService.markScheduled(id: task.id, eventId: eventId, date: slotStart)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        toastState.showSuccess(
            "\(task.title) → \(fmt.string(from: slotStart))",
            icon: "calendar.badge.plus"
        ) {
            reminderService.removeLocalEvent(id: eventId)
            backlogService.updateTask(taskSnapshot)
        }
    }
}

// MARK: - Planner slot row

/// Lightweight free-slot drop target for the planner's day column —
/// the popover's `FreeSlotRow` carries picker/pomodoro affordances the
/// planner doesn't need; this row is just «free time, drop here».
private struct PlannerSlotRow: View {
    let start: Date
    let end: Date
    let onDrop: (BacklogTaskDrag) -> Void

    @State private var isTargeted = false
    @Environment(\.activeSkin) private var skin

    private var durationLabel: String {
        DS.formatMinutes(Int(end.timeIntervalSince(start) / 60))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("H:mm")
        return f
    }()

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("Free · \(durationLabel)")
                .font(.subheadline.weight(.regular))
                .foregroundStyle(skin.resolvedTextSecondary)
            Text("\(Self.timeFormatter.string(from: start))–\(Self.timeFormatter.string(from: end))")
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .fill(isTargeted
                      ? skin.accentColor.opacity(DS.Opacity.mediumFill)
                      : skin.resolvedTextPrimary.opacity(DS.Opacity.subtleFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .strokeBorder(
                    isTargeted ? skin.accentColor : skin.resolvedTextTertiary.opacity(DS.Opacity.mutedStroke),
                    style: StrokeStyle(lineWidth: DS.Border.thin, dash: [4, 3])
                )
        )
        .dropDestination(for: BacklogTaskDrag.self) { items, _ in
            guard let dropped = items.first else { return false }
            Haptics.alignment()
            onDrop(dropped)
            return true
        } isTargeted: { targeted in
            withAnimation(DS.Animation.quick) { isTargeted = targeted }
        }
        .accessibilityLabel("Free slot, \(durationLabel). Drop a task to schedule it here.")
    }
}
