import SwiftUI
import BuboDomain

// MARK: - Roll forward (J-Recover)

extension MenuBarView {

    /// Whether the «Roll forward» banner should surface above the
    /// timeline. Three gates compose: it's after working hours, the
    /// banner hasn't been dismissed for today, and there's at least
    /// one task scheduled for today that isn't done yet.
    var shouldShowRollForward: Bool {
        let cal = Calendar.current
        let endHour = optimizerService.workingHoursEnd
        guard cal.component(.hour, from: nowTick) >= endHour else { return false }
        if let dismissedDay = rollForwardDismissedDay,
           cal.isDate(dismissedDay, inSameDayAs: nowTick) {
            return false
        }
        return unfinishedTodayCount > 0
    }

    /// Tasks scheduled for today that haven't been completed yet.
    /// Drives both the gate above and the banner's headline copy.
    var unfinishedTodayCount: Int {
        guard let backlog = optimizerService.backlogService else { return 0 }
        let cal = Calendar.current
        return backlog.tasks.filter { task in
            guard task.status == .scheduled,
                  let scheduled = task.scheduledDate
            else { return false }
            return cal.isDate(scheduled, inSameDayAs: nowTick)
        }.count
    }

    /// Roll today's incomplete tasks back into the backlog. The
    /// optimizer is NOT auto-run here — the user can tap «Plan
    /// tomorrow» (a ranked chip) afterwards if they want auto-
    /// scheduling. Restores the original schedule on undo.
    func performRollForward() {
        guard let backlog = optimizerService.backlogService else { return }
        let snapshots = backlog.rollTodayForward(now: nowTick)
        guard !snapshots.isEmpty else { return }
        let count = snapshots.count
        toastState.showSuccess(
            count == 1
                ? "Rolled 1\u{00A0}task to backlog"
                : "Rolled \(count)\u{00A0}tasks to backlog",
            icon: "moon.stars.fill"
        ) { [backlog] in
            // Undo: restore each task's pre-roll snapshot. Order
            // doesn't matter — `updateTask` is idempotent on each
            // task's id.
            for snapshot in snapshots {
                backlog.updateTask(snapshot)
            }
        }
        // Hide the banner for the rest of the day so it doesn't
        // re-prompt after the action.
        rollForwardDismissedDay = Calendar.current.startOfDay(for: nowTick)
        notifyScheduleChange()
    }

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
