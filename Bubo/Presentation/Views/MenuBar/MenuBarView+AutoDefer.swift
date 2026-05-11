import SwiftUI

// MARK: - Auto Defer

extension MenuBarView {

    /// Schedule a one-shot Timer that fires ~1 minute past midnight to
    /// re-run AutoDefer for users who leave the popover open overnight.
    /// `runAutoDeferIfNeeded` is the only consumer; the timer reschedules
    /// itself to the next midnight after each fire.
    ///
    /// Idempotent — calling twice doesn't stack timers; the second call
    /// drops out because `dayRolloverTimer != nil`. Cleared by
    /// `onDisappear` so a popover dismissal doesn't leak it.
    @MainActor
    func scheduleDayRolloverTimerIfNeeded() {
        guard dayRolloverTimer == nil else { return }
        scheduleNextDayRollover()
    }

    @MainActor
    func scheduleNextDayRollover() {
        let cal = Calendar.current
        let now = Date()
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        // Sleep ~60s past midnight so we cross the boundary cleanly,
        // not at the exact second of rollover (where small clock drift
        // could land us back on the previous day).
        let fireDate = startOfTomorrow.addingTimeInterval(60)
        let interval = max(60, fireDate.timeIntervalSinceNow)

        dayRolloverTimer?.invalidate()
        dayRolloverTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            // Hop to the main actor — Timer callbacks land on the run
            // loop's actor (typically not @MainActor).
            Task { @MainActor in
                runAutoDeferIfNeeded()
                // Reschedule for the next day. Recursive call is safe:
                // each iteration creates one timer; the prior is
                // invalidated by `dayRolloverTimer?.invalidate()` above.
                scheduleNextDayRollover()
            }
        }
    }

    /// Run the once-per-day backlog deferral pass. Wired from `onAppear`
    /// so every popover open during a fresh calendar day catches up the
    /// overdue tasks; the service itself early-exits when today's run
    /// already happened. The toast threading mirrors `runQuickAction`'s
    /// undo channel — same `arrow.uturn.backward` icon language as the
    /// optimizer's reversible operations.
    @MainActor
    func runAutoDeferIfNeeded() {
        guard let backlog = optimizerService.backlogService else { return }
        // Take the same once-a-day hook to prune stale per-event
        // constraints (locks / exclusions whose events have been
        // deleted upstream). Keeps the persistent sets from
        // accumulating dead ids — see `pruneStaleEventConstraints`.
        optimizerService.pruneStaleEventConstraints(reminderService: reminderService)

        let service = AutoDeferService(backlogService: backlog)
        let report = service.runIfNeeded()
        guard report.count > 0 else { return }
        let headline = report.count == 1
            ? "1 overdue task moved to tomorrow"
            : "\(report.count) overdue tasks moved to tomorrow"
        toastState.showSuccess(headline, icon: "arrow.uturn.backward") {
            // Undo runs the captured restore closure on the main actor.
            // Wrapping the call in `Task` lets us keep the toast's
            // synchronous Undo signature without forcing AutoDefer to
            // expose a sync rollback path.
            Task { await report.undo() }
        }
    }

    // MARK: - End-of-Day Banner (J10)

    /// J10 placement gate. Visible only when:
    ///   1. The day has already crossed `workingHours.upperBound` (so the
    ///      banner doesn't pop up at lunch), AND
    ///   2. The user hasn't dismissed it for today yet, AND
    ///   3. There's actual unfinished work to carry — pending tasks the
    ///      user has likely been ignoring through the day.
    var shouldShowEndOfDayBanner: Bool {
        let cal = Calendar.current
        let now = Date()
        let currentHour = cal.component(.hour, from: now)
        let currentMinute = cal.component(.minute, from: now)
        // A whole-hour comparison reads "after 18:00" as currentHour >=
        // workingHoursEnd; the minute check keeps the banner from
        // appearing right at the boundary on the dot — wait until 5 min
        // past the close, so a popover open at exactly the bell doesn't
        // greet the user with a wind-down nag.
        let pastEnd = currentHour > optimizerService.workingHoursEnd
            || (currentHour == optimizerService.workingHoursEnd && currentMinute >= 5)
        guard pastEnd else { return false }
        guard eodDismissedDay != Self.dayKey(for: now) else { return false }
        return eodUnfinishedCount > 0
    }

    /// Number of pending backlog tasks at the moment the banner is
    /// rendered. Excludes scheduled / done / frozen — only the rows the
    /// user would actually want pushed forward.
    var eodUnfinishedCount: Int {
        optimizerService.backlogService?.pending.count ?? 0
    }

    /// Stamp the current calendar day as «banner dismissed» — the
    /// `@AppStorage` write triggers a re-render, the gate above flips
    /// false, and the banner fades. Resets implicitly tomorrow because
    /// the day-key string no longer matches.
    func dismissEndOfDayBannerForToday() {
        eodDismissedDay = Self.dayKey(for: Date())
    }

    /// J10: bulk carry-forward. Each pending task gets its `createdAt`
    /// refreshed (so «stale» logic doesn't punish it on day N+1) and a
    /// single undo toast restores the prior `createdAt` values atomically.
    /// Doesn't touch deadlines or schedule slots — those are deliberate
    /// commitments, not «didn't get to it today» drift.
    func carryUnfinishedToTomorrow() {
        guard let backlog = optimizerService.backlogService else { return }
        let now = Date()
        let pending = backlog.pending
        guard !pending.isEmpty else { return }

        // Snapshot pre-carry state so undo restores `createdAt` exactly.
        let snapshots = pending.map { $0 }

        for var task in pending {
            task.createdAt = now
            backlog.updateTask(task)
        }

        let count = snapshots.count
        let headline = count == 1
            ? "Carried 1\u{00A0}task to tomorrow"
            : "Carried \(count)\u{00A0}tasks to tomorrow"
        toastState.showSuccess(headline, icon: "arrow.uturn.backward") {
            for original in snapshots {
                backlog.updateTask(original)
            }
        }
        dismissEndOfDayBannerForToday()
    }

    /// Compact «YYYY-MM-DD» key used to scope the banner's dismissal to
    /// a single calendar day. Locale-independent (we don't want a
    /// locale change between sessions to resurrect the banner). Static
    /// so the same formatter is reused across calls.
    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }
}
