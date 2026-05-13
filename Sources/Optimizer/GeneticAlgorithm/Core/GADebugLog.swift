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
public enum GADebugLog {

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
    public static func warn(
        site: String,
        message: String,
        context: [String: String] = [:]
    ) {
        let ctxStr = context.isEmpty
            ? ""
            : " (" + context.map { "\($0)=\($1)" }.sorted().joined(separator: ", ") + ")"
        let line = "\(site): \(message)\(ctxStr)"
        // `.private` — the `ctxStr` bag routinely embeds event ids and
        // titles from user calendars. Support reports can bring these
        // in by enabling private logging via `log config` or by
        // running a debug build.
        logger.warning("\(line, privacy: .private)")
        mirror.warning("\(line, privacy: .private)")
    }

    /// Convenience: no-context form.
    public static func warn(_ site: String, _ message: String) {
        warn(site: site, message: message, context: [:])
    }

    // MARK: - Trace channel (DEBUG-only)

    /// Per-generation / per-operator detail. Compiled out of release
    /// so production runs never pay the string formatting cost.
    ///
    /// `@inline(__always)` + `@autoclosure` together guarantee the
    /// call site collapses to zero instructions in release builds:
    /// the `#if DEBUG` strips the body, the inliner sees an empty
    /// function and inlines it, and the `@autoclosure` argument is
    /// never evaluated (its body — typically a `String(format:)`
    /// call — doesn't run). Without `@inline(__always)` the compiler
    /// *usually* inlines small empty functions under `-O` but
    /// doesn't have to; the explicit hint makes it a guarantee.
    ///
    /// We use `@inline(__always)` rather than `@inlinable` because
    /// Bubo is a single-module target — `@inlinable`'s cross-module
    /// machinery buys nothing here and would force every referenced
    /// internal symbol (`logger`, `warn`, the formatters) to be
    /// `@usableFromInline`. `@inline(__always)` gives the same
    /// release-build guarantee without the visibility dance.
    @inline(__always)
    public static func trace(_ site: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        logger.debug("[\(site, privacy: .public)] \(message(), privacy: .private)")
        #endif
    }

    // MARK: - Invariant helpers

    /// Check that a gene's `slotIndex` resolves to its `startTime` via
    /// the registry. A mismatch means some writer went through
    /// `ScheduleGene(...)` without going through the helpers that keep
    /// the two fields in sync — that's a bug, the kind you can't see
    /// until fitness drifts in a way that doesn't match the visible
    /// placement. No-op in release; `@inline(__always)` guarantees
    /// the empty body collapses to zero instructions at call sites
    /// so the per-gene-per-repair-call check costs nothing in
    /// production.
    @inline(__always)
    public static func assertSlotBinding(
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
    /// crossover output. No-op in release; `@inline(__always)`
    /// collapses the call to zero instructions.
    @inline(__always)
    public static func assertWorkingDay(
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
