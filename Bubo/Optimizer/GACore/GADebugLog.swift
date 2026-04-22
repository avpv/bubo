import Foundation
import OSLog

// MARK: - GA Debug Log

/// Structured debug logger for PlanWeek / GA diagnostics. Two channels:
///
///   * **`warn`** — things that shouldn't happen but might. Always
///     emitted at `.warning` OSLog level (even in release) because if
///     one of these fires, a real bug has already slipped past the
///     invariants and the user needs to see it in any collected log
///     bundle.
///
///   * **`trace`** — per-generation / per-operator detail. Compiled out
///     of release builds via `#if DEBUG`; in debug it's at `.debug`
///     level so it stays quiet unless you've filtered the Console app
///     to that category.
///
/// Both route through `com.avpv.Bubo:GADebug` so a single OSLog
/// predicate in Console / `log show` catches everything. Filter by
/// level to pick the channel:
///
/// ```
/// # All warnings (invariant + input anomalies)
/// log show --predicate 'subsystem == "com.avpv.Bubo"
///                       AND category == "GADebug"' --level warning
///
/// # Full debug trace (DEBUG builds)
/// log show --predicate 'subsystem == "com.avpv.Bubo"
///                       AND category == "GADebug"' --level debug
/// ```
///
/// Warnings are also mirrored to `PlanWeek` so they show up alongside
/// the run's input/result lines in the same log bundle the user would
/// share.
enum GADebugLog {

    private static let logger = Logger(
        subsystem: "com.avpv.Bubo",
        category: "GADebug"
    )

    private static let mirror = Logger(
        subsystem: "com.avpv.Bubo",
        category: "PlanWeek"
    )

    // MARK: - Warn channel

    /// Report an invariant violation or suspicious input. The shape is
    /// `<site>: <message> (<context>)`, where `site` names the check
    /// (e.g. "slotBinding", "weekendPlacement", "fitnessDrop",
    /// "input") and `context` is a free-form dictionary formatted as
    /// `key=value, key=value`.
    ///
    /// Emitted at OSLog's `.warning` level so a single
    /// `--level warning` filter surfaces every instance across the
    /// run.
    static func warn(
        site: String,
        message: String,
        context: [String: String] = [:]
    ) {
        let ctxStr = context.isEmpty
            ? ""
            : " (" + context.map { "\($0)=\($1)" }.sorted().joined(separator: ", ") + ")"
        let line = "\(site): \(message)\(ctxStr)"
        logger.warning("\(line, privacy: .public)")
        mirror.warning("\(line, privacy: .public)")
    }

    /// Convenience: no-context form.
    static func warn(_ site: String, _ message: String) {
        warn(site: site, message: message, context: [:])
    }

    // MARK: - Trace channel (DEBUG-only)

    /// Per-generation / per-operator detail. Compiled out of release
    /// so production runs never pay the string formatting cost.
    static func trace(_ site: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        logger.debug("[\(site, privacy: .public)] \(message(), privacy: .public)")
        #endif
    }

    // MARK: - Invariant helpers

    /// Check that a gene's `slotIndex` resolves to its `startTime` via
    /// the registry. A mismatch means some writer went through
    /// `ScheduleGene(...)` without going through the helpers that keep
    /// the two fields in sync — that's a bug, the kind you can't see
    /// until fitness drifts in a way that doesn't match the visible
    /// placement. No-op in release.
    static func assertSlotBinding(
        _ gene: ScheduleGene,
        registry: SlotRegistry,
        site: String
    ) {
        #if DEBUG
        guard let slot = gene.slotIndex else { return }
        guard let date = registry.resolvedDate(at: slot) else {
            warn(
                site: "slotBinding",
                message: "slotIndex out of range",
                context: [
                    "where": site,
                    "event": gene.eventId,
                    "slot": "\(slot)",
                    "registry_count": "\(registry.count)"
                ]
            )
            return
        }
        let drift = abs(date.timeIntervalSinceReferenceDate - gene.startTime.timeIntervalSinceReferenceDate)
        if drift > 30 {  // 30-second tolerance for float shenanigans
            warn(
                site: "slotBinding",
                message: "slotIndex doesn't match startTime",
                context: [
                    "where": site,
                    "event": gene.eventId,
                    "slot": "\(slot)",
                    "slot_time": Self.timeFmt.string(from: date),
                    "gene_time": Self.timeFmt.string(from: gene.startTime),
                    "drift_sec": "\(Int(drift))"
                ]
            )
        }
        #endif
    }

    /// Check that an active gene sits on a working day under the
    /// configured preferences. Used after any mutation / repair /
    /// crossover output. Fires when the slot-decoder invariants are
    /// supposed to forbid this — a hit means something slipped through.
    static func assertWorkingDay(
        _ gene: ScheduleGene,
        preferences: OptimizerPreferences,
        calendar: Calendar,
        site: String
    ) {
        #if DEBUG
        guard gene.isIncluded else { return }
        if !preferences.isWorkingDay(gene.startTime, calendar: calendar) {
            warn(
                site: "weekendPlacement",
                message: "included gene on non-working day",
                context: [
                    "where": site,
                    "event": gene.eventId,
                    "day": Self.dayFmt.string(from: gene.startTime),
                    "workingDays": preferences.workingDays.sorted().map(String.init).joined(separator: ",")
                ]
            )
        }
        #endif
    }

    // MARK: - Formatters

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE dd.MM HH:mm"
        return f
    }()
}
