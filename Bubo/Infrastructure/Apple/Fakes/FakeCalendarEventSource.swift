import Foundation
import BuboDomain

// MARK: - Fake Calendar Event Source

/// Test / preview double for `CalendarEventSource`. Lives in the app
/// target (rather than the test bundle) so SwiftUI previews can drive
/// `ReminderService` and `EventKitSyncCoordinator` without hitting a
/// real `EKEventStore` — which requires user consent + entitlements
/// that neither XCTest nor `#Preview` can provide.
///
/// Records every call into `invocations` so tests can assert on order +
/// arguments, and exposes `upcomingEvents` so fetch results can be
/// swapped between runs.
final class FakeCalendarEventSource: CalendarEventSource {
    enum Invocation: Equatable {
        case triggerRemoteRefresh
        case fetchEvents(from: Date, to: Date, onlyCalendarIds: [String])
        case createEvent(id: String, calendarId: String?)
        case shiftEventTime(id: String, byMinutes: Int)
    }

    // MARK: - Configurable state

    var hasAccess: Bool
    var upcomingEvents: [CalendarEvent]
    var createEventError: Error?
    var shiftEventError: Error?

    // MARK: - Recorded calls

    private(set) var invocations: [Invocation] = []

    init(
        hasAccess: Bool = true,
        upcomingEvents: [CalendarEvent] = []
    ) {
        self.hasAccess = hasAccess
        self.upcomingEvents = upcomingEvents
    }

    // MARK: - Conformance

    func triggerRemoteRefresh() {
        invocations.append(.triggerRemoteRefresh)
    }

    func fetchEvents(
        from: Date, to: Date, onlyCalendarIds: [String]
    ) -> [CalendarEvent] {
        invocations.append(.fetchEvents(from: from, to: to, onlyCalendarIds: onlyCalendarIds))
        return upcomingEvents.filter { $0.startDate >= from && $0.startDate < to }
    }

    func createEvent(_ event: CalendarEvent, calendarId: String?) throws {
        invocations.append(.createEvent(id: event.id, calendarId: calendarId))
        if let err = createEventError { throw err }
        upcomingEvents.append(event)
    }

    func shiftEventTime(id: String, byMinutes minutes: Int) throws {
        invocations.append(.shiftEventTime(id: id, byMinutes: minutes))
        if let err = shiftEventError { throw err }
        guard let idx = upcomingEvents.firstIndex(where: { $0.id == id }) else { return }
        let offset = TimeInterval(minutes * 60)
        upcomingEvents[idx].startDate = upcomingEvents[idx].startDate.addingTimeInterval(offset)
        upcomingEvents[idx].endDate = upcomingEvents[idx].endDate.addingTimeInterval(offset)
    }
}
