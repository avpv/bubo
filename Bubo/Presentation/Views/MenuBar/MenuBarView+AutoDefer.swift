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
    /// already happened.
    @MainActor
    func runAutoDeferIfNeeded() {
        guard let backlog = optimizerService.backlogService else { return }
        optimizerService.pruneStaleEventConstraints(reminderService: reminderService)

        let service = AutoDeferService(backlogService: backlog)
        let report = service.runIfNeeded()

        guard report.count > 0 else { return }
        let headline = report.count == 1
            ? "1 overdue task moved to tomorrow"
            : "\(report.count) overdue tasks moved to tomorrow"
        toastState.showSuccess(headline, icon: "arrow.uturn.backward") {
            Task { await report.undo() }
        }
    }
}
