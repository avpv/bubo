import SwiftUI
import BuboDomain

// MARK: - Backlog reorder helpers
//
// Up/down moves, edge moves and drag-reorder drop handling.
// Extracted from BacklogFullscreenView.swift.

extension BacklogFullscreenView {

// MARK: - Reorder helpers
    //
    // Mirror BacklogView's behaviour so users get identical reorder semantics
    // across the two surfaces.

    func canMoveUp(_ task: BacklogTask) -> Bool {
        visibleTasks.first?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    func canMoveDown(_ task: BacklogTask) -> Bool {
        visibleTasks.last?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    /// Move keyboard focus between visible rows. Boundaries clamp silently —
    /// no wrap-around. Identical to BacklogView so the two views share muscle
    /// memory.
    func focusRow(offsetFrom currentId: String, by delta: Int) {
        let tasks = visibleTasks
        guard let idx = tasks.firstIndex(where: { $0.id == currentId }) else { return }
        let target = idx + delta
        guard target >= 0, target < tasks.count else { return }
        focusedTaskId = tasks[target].id
    }

    /// Reorder by ±1 slot via keyboard / context menu. Honours user-order
    /// only; in smart-sort mode the call still mutates storage order, but
    /// the visible position depends on the score — same as BacklogView.
    func moveTask(_ task: BacklogTask, by delta: Int) {
        let ordered = visibleTasks
        guard let current = ordered.firstIndex(where: { $0.id == task.id }) else { return }
        let target = current + delta
        guard ordered.indices.contains(target) else { return }
        let targetId = ordered[target].id

        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if delta < 0 {
                backlogService.moveTask(id: task.id, before: targetId)
            } else if target + 1 < ordered.count {
                backlogService.moveTask(id: task.id, before: ordered[target + 1].id)
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }

        let taskId = task.id
        onUndoableAction?("Reordered \u{201C}\(task.title)\u{201D}") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    func moveTaskToEdge(_ task: BacklogTask, toTop: Bool) {
        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if toTop {
                if let firstVisible = visibleTasks.first, firstVisible.id != task.id {
                    backlogService.moveTask(id: task.id, before: firstVisible.id)
                }
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }
        let taskId = task.id
        onUndoableAction?("Moved \u{201C}\(task.title)\u{201D} to \(toTop ? "top" : "bottom")") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    /// Drop one task onto another to reorder. If the dropped task and the
    /// target live in different context groups, the dropped task adopts the
    /// target's context (otherwise grouping would silently undo the visual
    /// move). Mirrors BacklogView's `handleReorderDrop` 1:1.
    func handleReorderDrop(dropped: BacklogTaskDrag, targetId: String) {
        guard dropped.taskId != targetId,
              let originalTask = backlogService.tasks.first(where: { $0.id == dropped.taskId }),
              backlogService.tasks.contains(where: { $0.id == targetId }),
              let target = backlogService.tasks.first(where: { $0.id == targetId })
        else { return }

        let previousIndex = backlogService.indexOfTask(id: originalTask.id)
        let previousContext = originalTask.context
        let contextChanged = originalTask.context != target.context

        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if contextChanged {
                var updated = originalTask
                updated.context = target.context
                backlogService.updateTask(updated)
            }
            backlogService.moveTask(id: originalTask.id, before: targetId)
        }

        let taskId = originalTask.id
        let originalSnapshot = originalTask
        onUndoableAction?(
            contextChanged
                ? "Moved \u{201C}\(originalTask.title)\u{201D} to \(target.context ?? "No project")"
                : "Reordered \u{201C}\(originalTask.title)\u{201D}"
        ) { [backlogService] in
            guard var current = backlogService.tasks.first(where: { $0.id == taskId }) else {
                backlogService.restoreTask(originalSnapshot, at: previousIndex)
                return
            }
            current.context = previousContext
            backlogService.updateTask(current)
            if let previousIndex {
                _ = backlogService.removeTask(id: taskId)
                backlogService.restoreTask(current, at: previousIndex)
            }
        }
    }

}
