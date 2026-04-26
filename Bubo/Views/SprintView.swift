import SwiftUI

// MARK: - Sprint View

/// Full-screen sprint mode that lives inside the popover navigation stack
/// — same pattern as `EditTaskView`. Replaces the old in-place "isSprintMode"
/// modifier on `BacklogView`, which only restyled rows while leaving the
/// rest of the popover (header, world clocks, banners, timeline) competing
/// for attention.
///
/// Design (Birman):
/// - One thing on screen at a time. Sprint is "what's next" — everything
///   that isn't a task is gone, including the brand chrome.
/// - The list itself stays inline-editable: complete with a tap, edit by
///   pushing the same `EditTaskView` the backlog uses, undo via toast.
/// - Caracass for future additions (active-task timer, focus-time
///   scheduling) without changing the entry point.
struct SprintView: View {
    var backlogService: BacklogService
    var onExit: () -> Void
    var onEditTask: (BacklogTask) -> Void
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hard cap on rows visible in sprint mode. Small on purpose: the whole
    /// point of the mode is to see exactly what's next without a scroll.
    static let maxTasks = 5

    /// Top `maxTasks` active tasks ordered by smart score — deadline urgency
    /// + priority — so "next" is genuinely next, not whatever the user
    /// happened to drag to the top of the canonical backlog.
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

    @ViewBuilder
    private var headerTrailing: some View {
        if !sprintTasks.isEmpty {
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
        }
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
            isSprintMode: true,
            onComplete: { complete(task) },
            onEdit: { onEditTask(task) },
            onDelete: { delete(task) }
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
