import Foundation
import BuboDomain

// MARK: - Calendar Event Source

/// Protocol abstraction over `AppleCalendarService` so consumers
/// (`EventKitSyncCoordinator`, `ReminderService`) can be driven with a
/// fake in tests without spinning up a real `EKEventStore` — EventKit
/// requires user-grantable entitlements that XCTest can't provide.
///
/// Production wires in `AppleCalendarService.shared`. Tests use
/// `FakeCalendarEventSource` (in the test target) which returns canned
/// `[CalendarEvent]` slices from `fetchEvents` and records the calls.
///
/// Static notification names (`calendarDataChanged`,
/// `authorizationDidChange`) stay on `AppleCalendarService` because
/// they're observer topics, not injected dependencies — tests that need
/// them just post matching notifications.
protocol CalendarEventSource: AnyObject {
    /// Whether the user has granted full calendar access. Forwards to
    /// `EKEventStore.authorizationStatus(for: .event)` in production.
    var hasAccess: Bool { get }

    /// Trigger an async remote refresh from all sources (iCloud, Google,
    /// Exchange, CalDAV). The actual data lands later via
    /// `EKEventStoreChanged`.
    func triggerRemoteRefresh()

    /// Freshness of the change-push channel: the later of «store
    /// (re)created» and «last `EKEventStoreChanged` received». The
    /// coordinator's self-heal compares this against the moment a
    /// poll-driven fetch discovers changed data — a live connection
    /// would have announced that change within seconds, so a long
    /// silence plus a data diff means the connection is dead.
    var lastPushActivityAt: Date { get }

    /// Recover a dead push connection by rebuilding the store. Called
    /// by the coordinator's self-heal only — never on the periodic
    /// sync path (rebuilding every sync is the PR #588 failure).
    func rebuildForSelfHeal()

    /// Fetch events in a date range, optionally restricted to a set of
    /// calendar IDs. Empty `onlyCalendarIds` means "all calendars".
    func fetchEvents(from: Date, to: Date, onlyCalendarIds: [String]) -> [CalendarEvent]

    /// Create a new event in Apple Calendar. Throws on EventKit errors.
    func createEvent(_ event: CalendarEvent, calendarId: String?) throws

    /// Shift an event's start and end time by `byMinutes`. Used by the
    /// snooze flow.
    func shiftEventTime(id: String, byMinutes: Int) throws
}

// MARK: AppleCalendarService conformance

extension AppleCalendarService: CalendarEventSource {
    /// Instance-property forward of the static `AppleCalendarService.hasAccess`
    /// so the protocol requirement is satisfied. Keeping the static property
    /// around for ergonomic view-side reads (`AppleCalendarService.hasAccess`).
    var hasAccess: Bool { AppleCalendarService.hasAccess }
}
