import Foundation
import OSLog

// MARK: - BuboLog — Unified Logging

/// Single entry point for all logging in Bubo. Wraps Apple's unified
/// logging (`os.Logger`) so every call site uses the same subsystem,
/// category layout, and event-format convention.
///
/// ## Why a wrapper
///
/// `os.Logger` is already fast and structured — the wrapper does **not**
/// add a layer of string formatting on top. Instead it:
///
///   * Pins the subsystem (`com.avpv.Bubo`) so a single `log show`
///     predicate catches every message from the app.
///   * Standardises category names as a slash-separated hierarchy
///     (`Services/EventCache`, `Optimizer/GA`, `App/Lifecycle`) so
///     grouping in Console.app and `--predicate 'category BEGINSWITH …'`
///     filtering both work.
///   * Gives call sites a `.event(_:…)` helper that emits one line per
///     structured event in a fixed `event_name k=v k=v` shape — this is
///     what makes it possible to grep / pipe logs into anything else.
///
/// ## Format
///
/// Every structured log line has the form:
///
///     <event_snake_case> k1=v1 k2=v2 ...
///
/// Rules:
///   * `event_name` is imperative_past: `sync_started`, `fetch_failed`,
///     `request_sent`. Lowercase, snake_case, no spaces.
///   * Keys are snake_case. Values are space-free (`path=/v1/x`,
///     `duration_ms=124`, `status=200`).
///   * Free-form strings with spaces must be quoted by the caller
///     (`title="deep work"`).
///   * PII / user content should be marked `.private`; IDs that need to
///     correlate across lines should be `.private(mask: .hash)`.
///
/// ## Performance guarantees
///
/// All log methods take their message as `@autoclosure () -> String` so
/// the work of formatting is deferred until `os.Logger` decides the
/// message is actually going to be persisted. Combined with
/// `#if DEBUG` around `.trace()`, this means:
///
///   * In release builds, `.trace()` call sites compile to zero
///     instructions.
///   * `.debug()` / `.info()` call sites pay only the branch cost when
///     the subsystem's level filter excludes them.
///   * `.notice()` / `.warning()` / `.error()` always emit (they're
///     persisted to disk by the OS) — the autoclosure still avoids the
///     allocation when the logger is inactive (e.g. during early boot).
///
/// ## Usage
///
/// ```swift
/// private let log = BuboLog.services("EventCache")
///
/// log.info("load_started", "count=\(events.count)")
///
/// do {
///     try context.save()
///     log.info("save_ok", "count=\(events.count)")
/// } catch {
///     log.error("save_failed", "error=\(error.localizedDescription)")
/// }
/// ```
struct BuboLog: Sendable {

    static let subsystem = "com.avpv.Bubo"

    let logger: Logger

    // MARK: - Factories (stable category taxonomy)

    /// `App/<area>` — application lifecycle, container wiring, AppDelegate.
    static func app(_ area: String) -> BuboLog {
        BuboLog(logger: Logger(subsystem: subsystem, category: "App/\(area)"))
    }

    /// `Services/<name>` — domain services (cache, sync, agent, reminders).
    static func services(_ name: String) -> BuboLog {
        BuboLog(logger: Logger(subsystem: subsystem, category: "Services/\(name)"))
    }

    /// `Network/<name>` — outbound HTTP, proxies, network monitoring.
    static func network(_ name: String) -> BuboLog {
        BuboLog(logger: Logger(subsystem: subsystem, category: "Network/\(name)"))
    }

    /// `Optimizer/<name>` — GA, constraint engine, planner diagnostics.
    static func optimizer(_ name: String) -> BuboLog {
        BuboLog(logger: Logger(subsystem: subsystem, category: "Optimizer/\(name)"))
    }

    /// `UI/<name>` — view-model side effects worth tracing (rare).
    static func ui(_ name: String) -> BuboLog {
        BuboLog(logger: Logger(subsystem: subsystem, category: "UI/\(name)"))
    }

    /// Escape hatch for code that doesn't fit the taxonomy. Prefer one
    /// of the named factories; only reach for this if inventing a new
    /// top-level area isn't justified yet.
    static func custom(category: String) -> BuboLog {
        BuboLog(logger: Logger(subsystem: subsystem, category: category))
    }

    // MARK: - Emit

    /// High-volume per-iteration trace. Compiled out of release builds
    /// so the call site has zero runtime cost.
    @inline(__always)
    func trace(_ event: String, _ fields: @autoclosure () -> String = "") {
        #if DEBUG
        let line = Self.line(event: event, fields: fields())
        logger.debug("\(line, privacy: .public)")
        #endif
    }

    /// Routine event that's useful during investigation but not
    /// interesting by default. Filtered to disk by `os.log` only when
    /// the user bumps the level (Console.app or `log config`).
    @inline(__always)
    func debug(_ event: String, _ fields: @autoclosure () -> String = "") {
        logger.debug("\(Self.line(event: event, fields: fields()), privacy: .public)")
    }

    /// Normal, expected event worth keeping in the log stream —
    /// lifecycle transitions, successful completions of multi-step
    /// flows, etc.
    @inline(__always)
    func info(_ event: String, _ fields: @autoclosure () -> String = "") {
        logger.info("\(Self.line(event: event, fields: fields()), privacy: .public)")
    }

    /// User-visible or operator-visible milestone — sync completed,
    /// feature toggled, proxy request forwarded. Persisted to disk.
    @inline(__always)
    func notice(_ event: String, _ fields: @autoclosure () -> String = "") {
        logger.notice("\(Self.line(event: event, fields: fields()), privacy: .public)")
    }

    /// Unexpected but recoverable condition. Always persisted.
    @inline(__always)
    func warning(_ event: String, _ fields: @autoclosure () -> String = "") {
        logger.warning("\(Self.line(event: event, fields: fields()), privacy: .public)")
    }

    /// Failure the user will feel. Always persisted.
    @inline(__always)
    func error(_ event: String, _ fields: @autoclosure () -> String = "") {
        logger.error("\(Self.line(event: event, fields: fields()), privacy: .public)")
    }

    // MARK: - Internal formatting

    /// Build the `event k=v k=v` line. Kept private + static so the
    /// autoclosure contract at call sites is obvious.
    @inline(__always)
    private static func line(event: String, fields: String) -> String {
        fields.isEmpty ? event : "\(event) \(fields)"
    }
}
