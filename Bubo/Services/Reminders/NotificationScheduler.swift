import AppKit
import Foundation
import UserNotifications

// MARK: - Notification Scheduler

/// Owns the timer-based reminder-firing pipeline: per-event `Timer`
/// invalidation, `firedReminders` dedup, UN notification delivery, and
/// the full-screen-alert bridge. Extracted from `ReminderService` so
/// that class stops mixing "I am the in-memory source of truth for
/// events" with "I operate run loops".
///
/// Ownership boundary: the scheduler is a pure sink. It receives
/// `[CalendarEvent]` slices from the orchestrator and decides what
/// timers to fire / cancel. It never fetches events, never persists
/// them, and doesn't talk to EventKit. That makes it trivially
/// replaceable in tests — just drive it with fixtures — and keeps the
/// 200 lines of UNNotificationCenter plumbing out of `ReminderService`.
@MainActor
@Observable
final class NotificationScheduler {
    /// Default when the user has no intervals configured.
    static let defaultReminderMinutes = [5]

    private var settings: ReminderSettings

    /// Per-event timer list keyed by `event.id`. `nonisolated(unsafe)`
    /// for the same reason as in `ReminderService` pre-split — the
    /// collection is only read/written on the main actor, but the
    /// `Timer` instances must be invalidable from `deinit`, which is
    /// `nonisolated`.
    private nonisolated(unsafe) var reminderTimers: [String: [Timer]] = [:]

    /// Reminder keys (`eventId_minutes`) that have already fired this
    /// session. Prevents double-firing when the event list re-arrives
    /// from a post-sync follow-up fetch.
    private var firedReminders: Set<String> = []

    init(settings: ReminderSettings) {
        self.settings = settings
        requestNotificationPermission()
    }

    deinit {
        for timers in reminderTimers.values {
            timers.forEach { $0.invalidate() }
        }
    }

    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
    }

    // MARK: - Reminder Intervals

    var defaultReminderMinutesList: [Int] {
        let enabled = settings.intervals.filter { $0.isEnabled }
        if !enabled.isEmpty {
            return enabled.map(\.minutes).sorted()
        }
        return Self.defaultReminderMinutes
    }

    func activeReminderMinutes(for event: CalendarEvent) -> [Int] {
        if let custom = event.customReminderMinutes {
            return custom
        }
        let enabled = settings.intervals.filter { $0.isEnabled }
        if !enabled.isEmpty {
            return enabled.map(\.minutes)
        }
        return Self.defaultReminderMinutes
    }

    // MARK: - Scheduling

    /// Schedule (or re-schedule) reminders for the given upcoming events.
    /// Cancels any existing timers for each event first so the method is
    /// idempotent — callers can pass the same set multiple times per
    /// sync cycle without leaking timers.
    func schedule(_ events: [CalendarEvent]) {
        for event in events where event.isUpcoming {
            cancel(eventId: event.id)
            var timers: [Timer] = []

            for minutes in activeReminderMinutes(for: event) {
                let key = "\(event.id)_\(minutes)"
                guard !firedReminders.contains(key) else { continue }

                let fireDate = event.startDate.addingTimeInterval(-TimeInterval(minutes * 60))
                guard fireDate > Date() else { continue }

                let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.fire(for: event, minutesBefore: minutes, isSnooze: false)
                        self?.firedReminders.insert(key)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
            }

            // Pomodoro phase-boundary alerts — uses the same Timer + fired
            // -key + UN/full-screen pipeline as pre-event reminders, so a
            // single `cancel(eventId:)` tears down both kinds at once.
            for alert in pomodoroPhaseAlerts(for: event) {
                guard !firedReminders.contains(alert.key) else { continue }
                guard alert.fireDate > Date() else { continue }

                let timer = Timer(fire: alert.fireDate, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.firePhaseAlert(for: event, alert: alert)
                        self?.firedReminders.insert(alert.key)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
            }

            if !timers.isEmpty {
                reminderTimers[event.id] = timers
            }
        }
    }

    /// Cancel outstanding timers for one event. Safe to call when no
    /// timers are registered — no-op in that case.
    func cancel(eventId: String) {
        reminderTimers[eventId]?.forEach { $0.invalidate() }
        reminderTimers.removeValue(forKey: eventId)
    }

    /// Cancel every outstanding timer. Used by the orchestrator's
    /// `stopSync` path; resets the firing pipeline so a subsequent
    /// `start` builds a fresh schedule.
    func cancelAll() {
        for timers in reminderTimers.values {
            timers.forEach { $0.invalidate() }
        }
        reminderTimers.removeAll()
    }

    /// Nuclear option: cancel everything, forget every fired key, and
    /// re-schedule from scratch. Used when settings change in a way that
    /// invalidates all currently-scheduled intervals (e.g. user toggled
    /// an interval off).
    func rescheduleAll(_ events: [CalendarEvent]) {
        for timers in reminderTimers.values {
            timers.forEach { $0.invalidate() }
        }
        reminderTimers.removeAll()
        firedReminders.removeAll()
        schedule(events)
    }

    /// Prune `firedReminders` for events that are no longer in the live
    /// window. Without this the set grows unbounded across a long-lived
    /// app session; with it the memory footprint stays proportional to
    /// the number of upcoming events.
    func pruneFiredReminders(keepingEventIds alive: Set<String>) {
        firedReminders = firedReminders.filter { key in
            guard let separator = key.lastIndex(of: "_") else { return false }
            let eventId = String(key[..<separator])
            return alive.contains(eventId)
        }
    }

    // MARK: - Firing

    private func fire(for event: CalendarEvent, minutesBefore: Int, isSnooze: Bool) {
        if settings.showSystemNotification {
            sendSystemNotification(for: event, minutesBefore: minutesBefore, isSnooze: isSnooze)
        }
        if settings.showFullScreenAlert {
            postFullScreenAlert(for: event, minutesBefore: minutesBefore)
        }
    }

    // MARK: - Pomodoro Phase Alerts

    /// One alert to be fired at a pomodoro phase boundary — end of a work
    /// round, end of a break, or end of the whole session. Built once per
    /// `schedule` pass from the event's `pomodoroConfig` so there's no
    /// running state to keep in sync.
    struct PhaseAlert: Equatable {
        let fireDate: Date
        let title: String
        let body: String
        /// Stable dedup key so re-scheduling the same event doesn't
        /// double-fire an alert that already went out this session.
        let key: String
    }

    /// Internal-scoped so tests can assert the alert plan for a given
    /// config without driving the timer pipeline.
    func pomodoroPhaseAlerts(for event: CalendarEvent) -> [PhaseAlert] {
        guard let config = event.pomodoroConfig else { return [] }

        var alerts: [PhaseAlert] = []
        var cursor: TimeInterval = 0
        let work = TimeInterval(config.workMinutes * 60)
        let shortBreak = TimeInterval(config.breakMinutes * 60)
        let longBreak = TimeInterval(config.longBreakMinutes * 60)

        for round in 1...config.rounds {
            cursor += work
            let workEnd = event.startDate.addingTimeInterval(cursor)

            if round < config.rounds {
                alerts.append(PhaseAlert(
                    fireDate: workEnd,
                    title: "Round \(round) / \(config.rounds) done",
                    body: "Take a \(config.breakMinutes)-min break",
                    key: "\(event.id)_phase_work\(round)"
                ))
                cursor += shortBreak
                let breakEnd = event.startDate.addingTimeInterval(cursor)
                alerts.append(PhaseAlert(
                    fireDate: breakEnd,
                    title: "Break over",
                    body: "Round \(round + 1) of \(config.rounds) — back to work",
                    key: "\(event.id)_phase_break\(round)"
                ))
            } else {
                // Last round: either a long break then done, or straight to done.
                if longBreak > 0 {
                    alerts.append(PhaseAlert(
                        fireDate: workEnd,
                        title: "All rounds done",
                        body: "Long break: \(config.longBreakMinutes) min",
                        key: "\(event.id)_phase_allrounds"
                    ))
                    cursor += longBreak
                    let sessionEnd = event.startDate.addingTimeInterval(cursor)
                    alerts.append(PhaseAlert(
                        fireDate: sessionEnd,
                        title: "Session complete",
                        body: event.title,
                        key: "\(event.id)_phase_done"
                    ))
                } else {
                    alerts.append(PhaseAlert(
                        fireDate: workEnd,
                        title: "Session complete",
                        body: event.title,
                        key: "\(event.id)_phase_done"
                    ))
                }
            }
        }
        return alerts
    }

    private func firePhaseAlert(for event: CalendarEvent, alert: PhaseAlert) {
        if settings.showSystemNotification {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            let request = UNNotificationRequest(
                identifier: "\(alert.key)_\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
        // Intentionally NO full-screen alert for phase transitions — they
        // fire every 5–25 min inside an active session, which would make
        // the full-screen flow noisy. The system banner + the timer UI
        // already surface the state change.
    }

    private func sendSystemNotification(
        for event: CalendarEvent, minutesBefore: Int, isSnooze: Bool
    ) {
        let content = UNMutableNotificationContent()
        if isSnooze {
            content.title = "Reminder (snoozed)"
        } else if minutesBefore <= 0 {
            content.title = "Meeting starting!"
        } else {
            content.title = "Meeting in \(minutesBefore) min"
        }

        content.body = "\(event.title)\n\(event.formattedTime)"
        if let location = event.location {
            content.body += "\n\(location)"
        }

        let request = UNNotificationRequest(
            identifier: "\(event.id)_\(minutesBefore)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postFullScreenAlert(for event: CalendarEvent, minutesBefore: Int) {
        NotificationCenter.default.post(
            name: .showFullScreenAlert,
            object: nil,
            userInfo: [
                "event": event,
                "minutesBefore": minutesBefore,
            ]
        )
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }
}

extension Notification.Name {
    static let showFullScreenAlert = Notification.Name("showFullScreenAlert")
}
