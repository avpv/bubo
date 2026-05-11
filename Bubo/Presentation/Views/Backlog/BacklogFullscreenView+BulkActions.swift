import SwiftUI

// MARK: - Backlog bulk actions + tombstones
//
// Bulk-select operations and frozen-task undo helpers.
// Extracted from BacklogFullscreenView.swift.

extension BacklogFullscreenView {

    // MARK: - Bulk actions

    /// Schedule every selected pending task in one optimizer run.
    /// Reuses the same `onScheduleBacklog` callback that powers the
    /// header «Plan» pill — bulk-select is just a filtered view of
    /// «schedule the unscheduled set», so we don't need a separate
    /// per-task scheduling path. After dispatch we exit selection so
    /// the toast surfaces over the regular list.
    func bulkSchedule() {
        Haptics.tap()
        let task = onScheduleBacklog
        exitSelection()
        guard let task else { return }
        Task { await task() }
    }

    /// Push every selected task's deadline forward by `days`. Mirrors
    /// the per-row «Snooze» behaviour but applied across the set in
    /// one undo unit. Tasks without an existing deadline get one
    /// computed from start-of-today + N days so the «defer» verb has
    /// a concrete meaning even on never-dated rows.
    func bulkDefer(days: Int) {
        let snapshots = selectedTasks
        guard !snapshots.isEmpty else { return }
        Haptics.tap()
        let cal = Calendar.current
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            for task in snapshots {
                var updated = task
                let base = task.deadline ?? cal.startOfDay(for: Date())
                if let pushed = cal.date(byAdding: .day, value: days, to: base) {
                    updated.deadline = pushed
                    backlogService.updateTask(updated)
                }
            }
        }
        exitSelection()
        let label = "Deferred \(snapshots.count)\u{00A0}task\(snapshots.count == 1 ? "" : "s") by \(days)\u{00A0}day\(days == 1 ? "" : "s")"
        onUndoableAction?(label) { [backlogService] in
            for snapshot in snapshots {
                backlogService.updateTask(snapshot)
            }
        }
    }

    /// Freeze (set-aside) every selected task. Same non-destructive
    /// «park this for now» semantics as the per-row context menu, but
    /// applied as a single undoable batch. Frozen tasks leave the
    /// active list and unschedule their calendar slots — the optimizer
    /// stops planning around them.
    func bulkFreeze() {
        let snapshots = selectedTasks
        guard !snapshots.isEmpty else { return }
        Haptics.tap()
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            for task in snapshots {
                backlogService.freezeTask(id: task.id)
            }
        }
        exitSelection()
        let label = "Froze \(snapshots.count)\u{00A0}task\(snapshots.count == 1 ? "" : "s")"
        onUndoableAction?(label) { [backlogService] in
            for snapshot in snapshots {
                backlogService.updateTask(snapshot)
                backlogService.unfreezeTask(id: snapshot.id)
            }
        }
    }

    /// Delete every selected task as one undoable batch. The undo
    /// closure restores each task at its original index so the user's
    /// drag-order is preserved across the round-trip — same contract
    /// as the per-row delete path.
    func bulkDelete() {
        let snapshots = selectedTasks
        guard !snapshots.isEmpty else { return }
        Haptics.tap()
        let indexes: [(BacklogTask, Int?)] = snapshots.map { ($0, backlogService.indexOfTask(id: $0.id)) }
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            for task in snapshots {
                _ = backlogService.removeTask(id: task.id)
            }
        }
        exitSelection()
        let label = "Deleted \(snapshots.count)\u{00A0}task\(snapshots.count == 1 ? "" : "s")"
        onUndoableAction?(label) { [backlogService] in
            // Restore in original-index order so earlier rows land
            // first and keep the storage sequence consistent for the
            // following `restoreTask` calls.
            for (task, index) in indexes.sorted(by: { ($0.1 ?? .max) < ($1.1 ?? .max) }) {
                backlogService.restoreTask(task, at: index)
            }
        }
    }

    // MARK: - Tombstones

/// Unfreeze a single task with an undo toast that re-freezes on tap.
    /// Same pattern as BacklogView, kept duplicated until the controllers
    /// themselves get extracted (out of scope for this refactor).
    func unfreezeOneWithUndo(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeTask(id: task.id)
        }
        onUndoableAction?("Unfroze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
            backlogService.freezeTask(id: snapshot.id)
        }
    }

    func unfreezeAllWithUndo() {
        let restoredIds = backlogService.frozen.map(\.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeAll()
        }
        onUndoableAction?("Unfroze \(restoredIds.count)\u{00A0}task\(restoredIds.count == 1 ? "" : "s")") { [backlogService] in
            for id in restoredIds { backlogService.freezeTask(id: id) }
        }
    }

}
