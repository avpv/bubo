import SwiftUI

// MARK: - Backlog row-level actions
//
// Per-task CRUD and inline-add flow.
// Extracted from BacklogFullscreenView.swift.

extension BacklogFullscreenView {

    // MARK: - Actions

    /// Open the compact creation form with whatever's been typed so far.
    /// Mirrors `BacklogView.openCreateWithDetails` so both backlog modes
    /// share the same ⇧↩ / "›" affordance behaviour.
    func openCreateWithDetails() {
        let parsed = parsedNewTaskTitle
        guard let onCreateTaskWithDetails else {
            addTask()
            return
        }
        let title = parsed.cleaned
        let duration = parsed.durationMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
        onCreateTaskWithDetails(title, duration)
        newTaskTitle = ""
        parsedNewTaskTitle = ("", nil)
        isInputFocused = false
    }

    func addTask() {
        let parsed = parsedNewTaskTitle
        let title = parsed.cleaned
        guard !title.isEmpty else { return }

        // Same duration priority as the inline `BacklogView`:
        // explicit parse > machine verb-guess > user default.
        let duration = parsed.durationMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
            ?? optimizerService.defaultTaskDurationMinutes

        // Match inline `BacklogView`: stamp the active project's name on
        // `context` so the task lands in the user's current view (local
        // Bubo projects need this — EK lists historically got it from
        // the Reminders round-trip).
        let task = BacklogTask(
            title: title,
            durationMinutes: duration,
            priority: .medium,
            context: activeProjectName
        )
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.addTask(task)
        }
        newTaskTitle = ""
        parsedNewTaskTitle = ("", nil)
    }

    func complete(_ task: BacklogTask) {
        // Tap-to-complete via checkbox already fires `Haptics.tap()` from
        // the press itself (`BacklogTaskRow.checkbox` + `IconPressStyle`),
        // so no haptic here. Hot-key completion (digits 1-9) is the other
        // entry path; the haptic for that case fires from the digit-shortcut
        // button before delegating into `complete(_:)`.
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.entrance, reduceMotion: reduceMotion)) {
            backlogService.completeTask(id: task.id)
        }
        onUndoableAction?("Completed \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    func delete(_ task: BacklogTask) {
        let originalIndex = backlogService.indexOfTask(id: task.id)
        _ = backlogService.removeTask(id: task.id)
        onUndoableAction?("\u{201C}\(task.title)\u{201D} deleted") { [backlogService] in
            backlogService.restoreTask(task, at: originalIndex)
        }
    }

    func freeze(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.freezeTask(id: task.id)
        }
        onUndoableAction?("Froze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    /// Update a task's deadline via the inline picker. Mirrors
    /// `BacklogView.updateTaskDeadline` so both backlog modes share the
    /// same undo + toast pipeline.
    func updateTaskDeadline(task: BacklogTask, to newDeadline: Date?) {
        let snapshot = task
        var updated = task
        updated.deadline = newDeadline
        guard updated != snapshot else { return }
        withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
            backlogService.updateTask(updated)
        }
        let label: String
        if let deadline = newDeadline {
            let formatted = deadline.formatted(date: .abbreviated, time: .shortened)
            label = "Set deadline on \u{201C}\(task.title)\u{201D} to \(formatted)"
        } else {
            label = "Cleared deadline on \u{201C}\(task.title)\u{201D}"
        }
        onUndoableAction?(label) { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    /// Toggle urgent state via today-end deadline. Mirrors the inline
    /// `BacklogView.toggleUrgent` so the context-menu acts identically in
    /// both modes.
    func toggleUrgent(_ task: BacklogTask) {
        let snapshot = task
        var updated = task
        let calendar = Calendar.current
        if let deadline = task.deadline, calendar.isDateInToday(deadline) {
            updated.deadline = nil
        } else {
            updated.deadline = calendar.date(
                bySettingHour: 23, minute: 59, second: 0, of: Date()
            ) ?? Date()
        }
        withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
            backlogService.updateTask(updated)
        }
        let label = updated.deadline == nil
            ? "Cleared urgent on \u{201C}\(task.title)\u{201D}"
            : "Marked \u{201C}\(task.title)\u{201D} urgent"
        onUndoableAction?(label) { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    func uncomplete(_ task: BacklogTask) {
        var restored = task
        restored.status = .pending
        restored.completedAt = nil
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.updateTask(restored)
        }
    }
}
