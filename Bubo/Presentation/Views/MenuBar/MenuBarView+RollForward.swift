import SwiftUI
import BuboDomain

// MARK: - Free-slot actions

extension MenuBarView {

    /// Create a focus block directly in the given slot, bypassing the optimizer.
    /// Same pattern as handleTaskDrop — direct event creation + undo toast.
    func fillSlotWithFocus(start: Date, end: Date) {
        Haptics.tap()
        let eventId = "focus-\(UUID().uuidString)"
        let event = CalendarEvent(
            id: eventId,
            title: "Focus Time",
            startDate: start,
            endDate: end,
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard,
            colorTag: .blue
        )
        reminderService.addLocalEvent(event)

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        toastState.showSuccess(
            "Focus \(fmt.string(from: start))–\(fmt.string(from: end))",
            icon: "sparkles"
        ) {
            reminderService.removeLocalEvent(id: eventId)
        }
        notifyScheduleChange(created: true)
    }

    /// Reschedule overdue tasks into a free slot.
    /// Removes old events, creates new ones packed from slot start, registers batch undo.
    func rescheduleOverdue(into start: Date, end: Date) {
        guard let backlog = optimizerService.backlogService else { return }
        Haptics.tap()

        let slotDuration = end.timeIntervalSince(start)
        // Pick overdue tasks sorted by deadline (soonest first), fitting into the slot.
        let sorted = backlog.overdue.sorted {
            ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
        }
        var remaining = slotDuration
        var toReschedule: [BacklogTask] = []
        for task in sorted {
            let dur = TimeInterval(task.durationMinutes * 60)
            guard dur <= remaining else { continue }
            toReschedule.append(task)
            remaining -= dur
        }
        guard !toReschedule.isEmpty else { return }

        // Remove old events, create new ones packed sequentially from slot start.
        struct Snapshot { let task: BacklogTask; let oldEventId: String?; let newEventId: String }
        var snapshots: [Snapshot] = []
        var cursor = start
        for task in toReschedule {
            let oldEventId = task.scheduledEventId
            // Manual reschedule collapses multi-chunk layouts back into a
            // single slot, so every prior chunk has to be cleared — not
            // just the primary one `scheduledEventId` points at.
            for eid in task.scheduledEventIds {
                reminderService.removeLocalEvent(id: eid)
            }
            if let old = oldEventId, !task.scheduledEventIds.contains(old) {
                reminderService.removeLocalEvent(id: old)
            }

            let dur = TimeInterval(task.durationMinutes * 60)
            let newEventId = "task-\(task.id)"
            let event = CalendarEvent(
                id: newEventId,
                title: task.title,
                startDate: cursor,
                endDate: cursor.addingTimeInterval(dur),
                location: nil,
                description: nil,
                calendarName: nil,
                eventType: .standard,
                colorTag: .green
            )
            reminderService.addLocalEvent(event)
            backlog.markScheduled(id: task.id, eventId: newEventId, date: cursor)
            snapshots.append(Snapshot(task: task, oldEventId: oldEventId, newEventId: newEventId))
            cursor = cursor.addingTimeInterval(dur)
        }

        let count = toReschedule.count
        toastState.showSuccess(
            "Rescheduled \(count)\u{00A0}task\(count == 1 ? "" : "s")",
            icon: "arrow.uturn.forward"
        ) {
            // Undo: remove new events, restore old events and scheduled state
            for snap in snapshots {
                reminderService.removeLocalEvent(id: snap.newEventId)
                if let old = snap.oldEventId {
                    // Restore the original event if we removed it
                    let original = CalendarEvent(
                        id: old,
                        title: snap.task.title,
                        startDate: snap.task.scheduledDate ?? start,
                        endDate: (snap.task.scheduledDate ?? start).addingTimeInterval(TimeInterval(snap.task.durationMinutes * 60)),
                        location: nil,
                        description: nil,
                        calendarName: nil,
                        eventType: .standard,
                        colorTag: .green
                    )
                    reminderService.addLocalEvent(original)
                }
                backlog.markScheduled(
                    id: snap.task.id,
                    eventId: snap.oldEventId ?? snap.newEventId,
                    date: snap.task.scheduledDate ?? start
                )
            }
        }
        notifyScheduleChange(created: true)
    }
}
