import SwiftUI

// MARK: - BacklogFullscreenTaskRow

/// The configured `BacklogTaskRow` used inside `BacklogFullscreenView`'s
/// plan list. Bundles every per-task callback the row needs so the host
/// gets a single «row» construction site instead of a 25-argument
/// `BacklogTaskRow(…)` call inside its body.
///
/// Co-located with `BacklogTaskRow` under `Components/` since this
/// struct's only job is to compose that row with its fullscreen-specific
/// wiring (per-task optimizer entry points, multi-select state, focus-
/// state binding, deadline-picker presentation). The plain inline
/// `BacklogView` does not use this layer — its row wiring is simpler
/// and lives inline.
///
/// Created as the "next leg of work" follow-up to BODY-SPLIT-PLAN's
/// deferred Backlog PR 10 (`mainContent`): the row builder was the
/// single biggest helper still on the host, so isolating it is the
/// step that makes a future `mainContent` carve realistic.
struct BacklogFullscreenTaskRow: View {
    let task: BacklogTask
    let hotKey: Int?
    let proposedSlot: Date?

    let isUrgent: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let isFocused: Bool
    let defaultTaskDurationMinutes: Int
    let selectionMode: Bool
    let isSelected: Bool

    @FocusState.Binding var focusedTaskId: String?

    let onComplete: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onFreeze: () -> Void
    let onReorderDrop: (BacklogTaskDrag) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onMoveToTop: () -> Void
    let onMoveToBottom: () -> Void
    let onFocusPrev: () -> Void
    let onFocusNext: () -> Void
    let onFindSlot: (() -> Void)?
    let onSetPreferredPeriod: (Period?) -> Void
    let onSplitTask: (() -> Void)?
    let onSnoozeByDays: (Int) -> Void
    let onReschedule: (() -> Void)?
    let onSetDeadline: () -> Void
    let onToggleUrgent: () -> Void
    let onLoadAlternatives: (() async -> [ScheduleScenario])?
    let onPickAlternative: ((ScheduleScenario) -> Void)?
    let onToggleSelection: () -> Void

    var body: some View {
        BacklogTaskRow(
            task: task,
            isUrgent: isUrgent,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            onComplete: onComplete,
            onEdit: onEdit,
            onDelete: onDelete,
            onFreeze: onFreeze,
            onReorderDrop: onReorderDrop,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onMoveToTop: onMoveToTop,
            onMoveToBottom: onMoveToBottom,
            isFocused: isFocused,
            onFocusPrev: onFocusPrev,
            onFocusNext: onFocusNext,
            proposedSlot: proposedSlot,
            sprintHotKey: hotKey,
            onFindSlot: onFindSlot,
            onSetPreferredPeriod: onSetPreferredPeriod,
            onSplitTask: onSplitTask,
            onSnoozeByDays: onSnoozeByDays,
            onReschedule: onReschedule,
            onSetDeadline: onSetDeadline,
            onToggleUrgent: onToggleUrgent,
            onLoadAlternatives: onLoadAlternatives,
            onPickAlternative: onPickAlternative,
            defaultTaskDurationMinutes: defaultTaskDurationMinutes,
            selectionMode: selectionMode,
            isSelected: isSelected,
            onToggleSelection: onToggleSelection
        )
        .focusable()
        .focused($focusedTaskId, equals: task.id)
        .focusEffectDisabled()
    }
}
