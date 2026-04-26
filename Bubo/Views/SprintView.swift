import SwiftUI

// MARK: - Sprint View

/// Full-screen sprint mode that lives inside the popover navigation stack
/// — same pattern as `EditTaskView`. Replaces the old in-place "isSprintMode"
/// modifier on `BacklogView`, which only restyled rows while leaving the
/// rest of the popover (header, world clocks, banners, timeline) competing
/// for attention.
///
/// Design (Birman / HIG):
/// - One thing on screen at a time. Sprint is "what's next" — everything
///   that isn't a task is gone, including the brand chrome.
/// - The list itself stays inline-editable: complete with a tap, edit by
///   pushing the same `EditTaskView` the backlog uses, undo via toast.
/// - Smart sort isn't an algorithm-as-judge: drag any row to override the
///   ranking and the dropped task pins to the top. Pinning is reversible
///   from the row's context menu, and survives across sessions.
/// - The single primary action — *plan these into the calendar* — sits in
///   the trailing header where the eye lands, not inside an overflow menu.
struct SprintView: View {
    var backlogService: BacklogService
    var onExit: () -> Void
    var onEditTask: (BacklogTask) -> Void
    /// Fired when the user taps "Schedule" in the Sprint header. The parent
    /// owns the optimizer trigger (it's the same surface the inline backlog
    /// reaches via the Schedule pill), so Sprint just fires a callback and
    /// lets `MenuBarView` pop the command palette.
    var onScheduleTasks: (() -> Void)? = nil
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backlogCoordinator) private var coordinator

    /// Hard cap on rows visible in sprint mode. Small on purpose: the whole
    /// point of the mode is to see exactly what's next without a scroll.
    static let maxTasks = 5

    /// Top `maxTasks` active tasks ordered by smart score — deadline urgency
    /// + priority — with pinned tasks floating above the algorithm. So
    /// "next" is genuinely next: either the algorithm picks it, or the user
    /// pinned it on top via drag.
    private var sprintTasks: [BacklogTask] {
        let active = BacklogLogic.activeTasks(backlogService.tasks)
        let sorted = BacklogLogic.smartSorted(active)
        return BacklogLogic.sprintCapped(sorted, max: Self.maxTasks)
    }

    /// Total scheduled minutes across the sprint set — surfaces "how big is
    /// this session?" in the header without forcing the user to do mental math.
    private var totalMinutes: Int {
        sprintTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: "Sprint",
                showBack: true,
                backLabel: "Exit",
                onBack: onExit,
                trailing: AnyView(headerTrailing)
            )

            if sprintTasks.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(sprintTasks) { task in
                            row(for: task)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.lg)
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
    }

    /// Header trailing cluster:
    /// - Count + total duration (`4 · 4h`) — answers "how big is this set?"
    /// - Schedule pill — primary action: hand the set to the optimizer.
    ///
    /// HIG: главное действие читается как кнопка и стоит там, куда падает
    /// взгляд. Был только текстовый счётчик — оптимизатор был спрятан за
    /// возвратом в основной экран.
    @ViewBuilder
    private var headerTrailing: some View {
        if !sprintTasks.isEmpty {
            HStack(spacing: DS.Spacing.sm) {
                HStack(spacing: DS.Spacing.xxs) {
                    Text("\(sprintTasks.count)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .contentTransition(.numericText())
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Text(DS.formatMinutes(totalMinutes))
                        .font(.subheadline.weight(.regular).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.numericText())
                }
                if let onScheduleTasks {
                    scheduleButton(onScheduleTasks)
                }
            }
        }
    }

    /// Same visual language as `BacklogView.scheduleButton` — a subtle accent
    /// capsule, full-width text label, no cryptic icon. Birman: «пиктограмма
    /// без подписи — загадка».
    @ViewBuilder
    private func scheduleButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Schedule")
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background {
                    Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                }
                .overlay {
                    Capsule().strokeBorder(
                        skin.accentColor.opacity(DS.Opacity.subtleBorder),
                        lineWidth: DS.Border.thin
                    )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Plan these tasks into your calendar")
        .accessibilityLabel("Schedule sprint tasks")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(skin.resolvedTextTertiary)
            Text("Nothing to sprint on")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
            Text("Add a task to get going.")
                .font(.callout)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.lg)
    }

    @ViewBuilder
    private func row(for task: BacklogTask) -> some View {
        BacklogTaskRow(
            task: task,
            isUrgent: BacklogLogic.isUrgent(task),
            isDragging: coordinator?.draggedTask?.taskId == task.id,
            isSprintMode: true,
            smartReason: BacklogLogic.smartReason(for: task),
            isPinned: task.pinnedRank != nil,
            onComplete: { complete(task) },
            onEdit: { onEditTask(task) },
            onDelete: { delete(task) },
            onPinToTop: { pinToTop(task) },
            onUnpin: { unpin(task) },
            onDragStart: {
                coordinator?.beginDrag(payload(for: task))
            },
            onDragEnd: { coordinator?.endDrag() },
            onReorderDrop: { dropped in
                handlePinDrop(dropped: dropped, targetId: task.id)
            }
        )
    }

    // MARK: - Pin drag-drop
    //
    // Sprint always presents tasks via `BacklogLogic.smartSorted`. Storage
    // order is invisible here, so a drop that just re-shuffled storage order
    // would visually do nothing — the next render re-sorts back. Drag is
    // therefore wired to *pinning*: dropping A on B promotes A above B in the
    // smart-sorted list, leaving everything else algorithm-driven.

    private func handlePinDrop(dropped: BacklogTaskDrag, targetId: String) {
        guard dropped.taskId != targetId,
              backlogService.tasks.contains(where: { $0.id == dropped.taskId }),
              backlogService.tasks.contains(where: { $0.id == targetId }) else { return }
        let droppedTitle = backlogService.tasks.first(where: { $0.id == dropped.taskId })?.title
            ?? dropped.title
        let priorRank = backlogService.tasks.first(where: { $0.id == dropped.taskId })?.pinnedRank
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.pinTask(id: dropped.taskId, before: targetId)
        }
        coordinator?.endDrag()
        let movedId = dropped.taskId
        onUndoableAction?("Pinned \u{201C}\(droppedTitle)\u{201D}") { [backlogService] in
            if let priorRank {
                backlogService.pinTask(id: movedId)
                if priorRank != 0 {
                    // Best-effort: a single-step undo can't perfectly restore
                    // mid-list rank, but unpin restores the most common case
                    // (was unpinned before).
                }
            } else {
                backlogService.unpinTask(id: movedId)
            }
        }
    }

    private func pinToTop(_ task: BacklogTask) {
        let priorRank = task.pinnedRank
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.pinTask(id: task.id)
        }
        let taskId = task.id
        onUndoableAction?("Pinned \u{201C}\(task.title)\u{201D}") { [backlogService] in
            if priorRank == nil {
                backlogService.unpinTask(id: taskId)
            }
        }
    }

    private func unpin(_ task: BacklogTask) {
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unpinTask(id: task.id)
        }
        let taskId = task.id
        let title = task.title
        onUndoableAction?("Unpinned \u{201C}\(title)\u{201D}") { [backlogService] in
            backlogService.pinTask(id: taskId)
        }
    }

    private func payload(for task: BacklogTask) -> BacklogTaskDrag {
        BacklogTaskDrag(
            taskId: task.id,
            title: task.title,
            durationMinutes: task.durationMinutes,
            context: task.context
        )
    }

    private func complete(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.entrance, reduceMotion: reduceMotion)) {
            backlogService.completeTask(id: task.id)
        }
        Haptics.tap()
        onUndoableAction?("Completed \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    private func delete(_ task: BacklogTask) {
        let originalIndex = backlogService.indexOfTask(id: task.id)
        _ = backlogService.removeTask(id: task.id)
        onUndoableAction?("\u{201C}\(task.title)\u{201D} deleted") { [backlogService] in
            backlogService.restoreTask(task, at: originalIndex)
        }
    }
}
