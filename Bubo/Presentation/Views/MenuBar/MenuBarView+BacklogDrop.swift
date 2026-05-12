import SwiftUI

// MARK: - Inline Backlog (drag-drop + slot-picker commit)
//
// All paths that take a backlog task and place it onto the calendar
// timeline: drag-to-free-slot, the slot picker's «pick existing» row,
// the right-click «Start top here» context menu, and the slot picker's
// batch commit (queue of mixed existing + brand-new items). All four
// share the toast/undo channel.

extension MenuBarView {

    /// Handle a backlog task being dropped onto a free slot.
    /// Resolves the drag payload, ends the drag session, and delegates
    /// to the shared `scheduleBacklogTask(_:slotStart:slotEnd:)` helper.
    func handleTaskDrop(drag: BacklogTaskDrag, slotStart: Date, slotEnd: Date) {
        guard let backlog = optimizerService.backlogService,
              let task = backlog.tasks.first(where: { $0.id == drag.taskId }) else { return }

        // Flip the discoverability hint off — this is a real drag-to-schedule,
        // so the user has learned the gesture. Same AppStorage key that
        // BacklogView reads via @AppStorage.
        UserDefaults.standard.set(true, forKey: "BuboBacklogHasDragged")

        // End the drag session cleanly so free-slot pulses stop immediately
        // — even if the drag-preview lifecycle callback hasn't fired yet.
        backlogCoordinator.endDrag()

        scheduleBacklogTask(task, slotStart: slotStart, slotEnd: slotEnd)
    }

    /// Place an existing backlog task into the calendar at the given slot.
    /// Shared path for drag-drop, the slot picker's «pick existing» row,
    /// and the right-click «Start top here» context menu — all three end
    /// up creating a calendar event, marking the task as scheduled, and
    /// surfacing a unified undo toast.
    ///
    /// Undo restores the task's full pre-schedule snapshot via
    /// `updateTask(snapshot)`, which cleanly reverses `markScheduled`
    /// because every mutable field returns to its pre-call value.
    func scheduleBacklogTask(_ task: BacklogTask, slotStart: Date, slotEnd: Date) {
        guard let backlog = optimizerService.backlogService else { return }

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
        // Clean up any prior chunks so a re-schedule collapses a
        // multi-slot layout into the single new slot rather than
        // leaving orphans.
        for eid in task.scheduledEventIds where eid != eventId {
            reminderService.removeLocalEvent(id: eid)
        }
        reminderService.addLocalEvent(event)
        backlog.markScheduled(id: task.id, eventId: eventId, date: slotStart)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        toastState.showSuccess(
            "\(task.title) → \(fmt.string(from: slotStart))",
            icon: "calendar.badge.plus"
        ) {
            reminderService.removeLocalEvent(id: eventId)
            backlog.updateTask(taskSnapshot)
            notifyScheduleChange(deleted: eventId)
        }
        notifyScheduleChange()
    }

    /// Slot-picker batch commit — the user opened the picker, queued
    /// some mix of existing backlog tasks and brand-new titles, and
    /// closed the popover. We place each item back-to-back from
    /// `slotStart`, capping the total at `slotEnd`, and surface a
    /// single toast covering the whole session so undo restores the
    /// entire batch in one click. Empty `items` is a no-op (user
    /// dismissed without queueing anything).
    ///
    /// Order matters: the picker preserves user-tap order, and so do
    /// we — placement starts at `slotStart` and the cursor advances
    /// by each item's duration. The last item is truncated if the
    /// queued total exceeded the slot, mirroring the single-task
    /// behaviour of `scheduleBacklogTask`. Items past a fully filled
    /// cursor are skipped rather than stacked elsewhere; the picker's
    /// auto-commit rule should prevent this in practice, but we
    /// double-check defensively because background re-syncs could
    /// have shrunk the slot between queue and commit.
    func scheduleSlotPickerBatch(
        items: [SlotPickerCommitItem],
        slotStart: Date,
        slotEnd: Date
    ) {
        guard !items.isEmpty,
              let backlog = optimizerService.backlogService else { return }

        // Per-placement undo closures, captured in placement order and
        // run in reverse so the schedule unwinds the way it was wound.
        var undoActions: [() -> Void] = []
        var placedEventIds: [String] = []

        var cursor = slotStart
        var firstStart: Date? = nil
        var lastEnd: Date? = nil

        for item in items {
            let remaining = slotEnd.timeIntervalSince(cursor)
            guard remaining > 0 else { break }

            switch item {
            case .existing(let task):
                let snapshot = task
                let duration = min(TimeInterval(task.durationMinutes * 60), remaining)
                let eventId = "task-\(task.id)"
                let event = CalendarEvent(
                    id: eventId,
                    title: task.title,
                    startDate: cursor,
                    endDate: cursor.addingTimeInterval(duration),
                    location: nil,
                    description: nil,
                    calendarName: nil,
                    eventType: .standard,
                    colorTag: .green
                )
                // Clean up any prior chunks so a re-schedule collapses a
                // multi-slot layout into the single new slot rather than
                // leaving orphans — same rule as `scheduleBacklogTask`.
                for eid in task.scheduledEventIds where eid != eventId {
                    reminderService.removeLocalEvent(id: eid)
                }
                reminderService.addLocalEvent(event)
                backlog.markScheduled(id: task.id, eventId: eventId, date: cursor)

                undoActions.append {
                    reminderService.removeLocalEvent(id: eventId)
                    backlog.updateTask(snapshot)
                }
                placedEventIds.append(eventId)

            case .create(_, let title, let durationMinutes):
                let task = BacklogTask(
                    title: title,
                    durationMinutes: durationMinutes,
                    priority: .medium
                )
                backlog.addTask(task)

                let duration = min(TimeInterval(durationMinutes * 60), remaining)
                let eventId = "task-\(task.id)"
                let event = CalendarEvent(
                    id: eventId,
                    title: title,
                    startDate: cursor,
                    endDate: cursor.addingTimeInterval(duration),
                    location: nil,
                    description: nil,
                    calendarName: nil,
                    eventType: .standard,
                    colorTag: .green
                )
                reminderService.addLocalEvent(event)
                backlog.markScheduled(id: task.id, eventId: eventId, date: cursor)

                let createdTaskId = task.id
                undoActions.append {
                    reminderService.removeLocalEvent(id: eventId)
                    _ = backlog.removeTask(id: createdTaskId)
                }
                placedEventIds.append(eventId)
            }

            if firstStart == nil { firstStart = cursor }
            cursor = cursor.addingTimeInterval(min(
                TimeInterval(item.durationMinutes * 60),
                remaining
            ))
            lastEnd = cursor
        }

        // Nothing actually got placed (slot collapsed under us between
        // queue and commit). Bail without a toast — the user gets a
        // silent no-op rather than a misleading «scheduled 0 tasks».
        guard !placedEventIds.isEmpty else { return }

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        let placedCount = placedEventIds.count
        let startStr = firstStart.map { fmt.string(from: $0) } ?? fmt.string(from: slotStart)

        // Single-item batches should read like the old single-task toast
        // so the common case doesn't regress in voice. Multi-item
        // batches show the count and the placed range.
        let message: String
        let icon: String
        if placedCount == 1 {
            let title = items.first.map(\.displayTitle) ?? ""
            message = "\(title) \u{2192} \(startStr)"
            icon = "calendar.badge.plus"
        } else {
            let endStr = lastEnd.map { fmt.string(from: $0) } ?? ""
            message = "\(placedCount)\u{00A0}tasks \u{2192} \(startStr)\u{2013}\(endStr)"
            icon = "calendar.badge.plus"
        }

        // Capture by value for the toast closure — it outlives this
        // function and runs on the main queue when the user taps undo.
        let undosCopy = undoActions
        let placedIdsCopy = placedEventIds
        toastState.showSuccess(message, icon: icon) {
            for undo in undosCopy.reversed() { undo() }
            for eid in placedIdsCopy {
                notifyScheduleChange(deleted: eid)
            }
        }
        notifyScheduleChange()
    }
}
