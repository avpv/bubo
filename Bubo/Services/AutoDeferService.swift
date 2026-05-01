import Foundation
import OSLog

// MARK: - Auto Defer Service

/// «The machine sweats so the human doesn't have to.» — Birman.
///
/// Once a day (typically right after the user opens the app on a fresh
/// morning), this service walks the backlog and pushes any task whose
/// `deadline` is in the past forward to *tomorrow* — i.e. the next
/// workday. The user wakes up to a backlog that already reflects the
/// new day's reality, instead of a wall of red «Overdue» rows.
///
/// Behaviour:
///
/// - Only `.pending` tasks are touched. Tasks already `.scheduled`
///   carry their slot forward automatically through the optimizer's
///   reapply path; tasks in `.done` are immutable.
/// - Tasks already deferred today (whose `modifiedAt` is within the
///   last `recentEditWindow`) are skipped — the user just touched them
///   and we shouldn't override their fresh edit. This is also what
///   makes the service idempotent on re-runs the same day.
/// - The replacement deadline is the `targetHour:` (default 09:00) of
///   the next valid workday — `workingDays` is honoured the same way
///   `BacklogLogic.remainingWorkdayMinutes` does it.
/// - Mutations go through `BacklogService.updateTask(_:)` so CloudKit
///   sync, undo coordination and the observer ripple all work the
///   same as if the user had edited each task by hand.
///
/// Wiring (deferred to a follow-up commit):
/// - `MenuBarView` should call `runIfNeeded()` from `onAppear` on a
///   day-rollover boundary. A `Timer.scheduledTimer(...)` keyed on
///   `Calendar.startOfDay(for:)` plus app-launch invocation covers
///   both «opened the app fresh today» and «left the app open
///   overnight» scenarios.
/// - The returned `DeferralReport` carries the count and the rollback
///   closure. `MenuBarView`'s host should pipe it into `ToastState`
///   the same way `runQuickAction` does on optimizer Run completion.
@MainActor
final class AutoDeferService {

    /// `BacklogService` is the only collaborator. We never touch
    /// `OptimizerService` here — the deferral is a pure data edit,
    /// not a re-optimisation. Birman: «не плодь сущности».
    private let backlogService: BacklogService

    /// Locale-aware calendar for day-boundary maths. Shared with
    /// `BacklogLogic.remainingWorkdayMinutes` so the two never disagree
    /// about what «today» means.
    private let calendar: Calendar

    /// Hour-of-day to set on the deferred task's new deadline. 09:00
    /// matches typical `workingHours.lowerBound`; callers can override
    /// for skins that ship a non-standard workday window.
    private let targetHour: Int

    /// Don't re-touch tasks edited within this window — they were just
    /// modified by the user (or by another sync) and probably already
    /// have a fresh deadline. 30 minutes is enough to skip an active
    /// editing session without holding genuinely-stale tasks back.
    private let recentEditWindow: TimeInterval

    /// Sticky «last successful run» timestamp, persisted in
    /// `UserDefaults` so a relaunch doesn't re-defer everything.
    /// `runIfNeeded()` early-exits when this falls within today.
    @MainActor
    private var lastRunDate: Date? {
        get {
            let stamp = UserDefaults.standard.double(forKey: Self.lastRunKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastRunKey)
        }
    }

    private static let lastRunKey = "BuboAutoDeferLastRun"
    private static let logger = Logger(subsystem: "Bubo", category: "AutoDefer")

    init(
        backlogService: BacklogService,
        calendar: Calendar = .current,
        targetHour: Int = 9,
        recentEditWindow: TimeInterval = 30 * 60
    ) {
        self.backlogService = backlogService
        self.calendar = calendar
        self.targetHour = targetHour
        self.recentEditWindow = recentEditWindow
    }

    // MARK: - Public API

    /// Report from a single `runIfNeeded` invocation. The caller wires
    /// this into a toast: `count` for the headline («3 tasks moved to
    /// tomorrow»), `undo` for the undo button. When `count == 0` the
    /// caller should suppress the toast — nothing happened.
    struct DeferralReport: Sendable {
        let count: Int
        let undo: @Sendable () async -> Void
    }

    /// Run a deferral pass if today's hasn't run yet. Idempotent within
    /// the same calendar day — repeated calls return a zero-count
    /// report without touching the backlog. Callers can force a re-run
    /// with `force: true` (used by tests / manual invocations).
    @discardableResult
    func runIfNeeded(now: Date = Date(), force: Bool = false) -> DeferralReport {
        if !force, hasRunToday(now: now) {
            return DeferralReport(count: 0, undo: {})
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let nextWorkdayStart = nextWorkdayStart(after: now)

        // Walk all `.pending` tasks; capture each task that needs to be
        // moved BEFORE mutation so the undo closure can put them back.
        var deferred: [(original: BacklogTask, newDeadline: Date)] = []
        for task in backlogService.tasks where task.status == .pending {
            guard let deadline = task.deadline else { continue }
            // Skip future-or-today deadlines — they're not «overdue» yet.
            guard deadline < startOfToday else { continue }
            // Skip tasks the user just edited.
            if let modifiedAt = task.modifiedAt,
               now.timeIntervalSince(modifiedAt) < recentEditWindow {
                continue
            }
            // The new deadline lands on the next workday at `targetHour`.
            // Fallback to plain `startOfTomorrow` if the calendar maths
            // fails, so we never silently skip a task on the «no
            // workdays in the next week» edge case.
            let newDeadline = nextWorkdayStart ?? startOfTomorrow
            deferred.append((original: task, newDeadline: newDeadline))
        }

        guard !deferred.isEmpty else {
            lastRunDate = now
            return DeferralReport(count: 0, undo: {})
        }

        // Apply.
        for (original, newDeadline) in deferred {
            var updated = original
            updated.deadline = newDeadline
            backlogService.updateTask(updated)
        }
        lastRunDate = now

        Self.logger.info("AutoDefer moved \(deferred.count) overdue task(s) forward")

        // The undo restores each original. We don't have to flip
        // `lastRunDate` back — the user undoing the deferral doesn't
        // mean we want to defer again on the next launch.
        let snapshot = deferred
        let serviceRef = backlogService
        let undo: @Sendable () async -> Void = { @MainActor in
            for entry in snapshot {
                serviceRef.updateTask(entry.original)
            }
        }

        return DeferralReport(count: deferred.count, undo: undo)
    }

    // MARK: - Internals

    /// Whether `runIfNeeded` already fired in today's calendar day.
    private func hasRunToday(now: Date) -> Bool {
        guard let lastRunDate else { return false }
        return calendar.isDate(lastRunDate, inSameDayAs: now)
    }

    /// Next workday's `targetHour`. Walks up to 14 days forward to skip
    /// weekends / opt-out days; the same termination guard
    /// `BacklogLogic.naiveProposedSlots` uses.
    private func nextWorkdayStart(after now: Date) -> Date? {
        let workingDays = WorkdayDefaults.workingDays()
        let startOfToday = calendar.startOfDay(for: now)
        var cursor = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        for _ in 0..<14 {
            let weekday = calendar.component(.weekday, from: cursor)
            if workingDays.isEmpty || workingDays.contains(weekday) {
                return calendar.date(bySettingHour: targetHour, minute: 0, second: 0, of: cursor)
                    ?? cursor
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return nil
    }
}

// MARK: - Workday defaults

/// Tiny helper that mirrors `OptimizerService`'s `workingDays` getter
/// without importing the full optimizer machinery into this service.
/// Reads the same `UserDefaults` key the optimizer writes to so the
/// two stay in sync — when the user changes their workday set in
/// settings, AutoDefer respects it on the next run automatically.
enum WorkdayDefaults {
    private static let workingDaysKey = "BuboOptimizerWorkingDays"

    /// 1-indexed weekday set (1 = Sunday, 7 = Saturday). Empty = «every
    /// day is a workday», matching the optimizer's contract.
    static func workingDays() -> Set<Int> {
        guard let raw = UserDefaults.standard.array(forKey: workingDaysKey) as? [Int] else {
            return []
        }
        return Set(raw)
    }
}
