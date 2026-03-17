import EventKit
import Foundation

/// Provides access to calendars configured in the native macOS Calendar.app
/// via EventKit. This includes iCloud, Exchange, Google, CalDAV, and any other
/// accounts the user has set up in System Settings → Internet Accounts.
class AppleCalendarService {
    private let store = EKEventStore()

    /// Current authorization status for calendar access.
    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Request access to the user's calendars. Returns true if access was granted.
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// List all calendars available in the system Calendar.app.
    func listCalendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                accountName: cal.source.title,
                color: cal.cgColor
            )
        }
    }

    /// Fetch events from selected Apple calendars within a date range.
    /// - Parameters:
    ///   - from: Start date
    ///   - to: End date
    ///   - onlyCalendarIds: If non-empty, only fetch from these calendar identifiers.
    func fetchEvents(from: Date, to: Date, onlyCalendarIds: [String] = []) -> [CalendarEvent] {
        let calendars: [EKCalendar]?
        if onlyCalendarIds.isEmpty {
            calendars = nil // all calendars
        } else {
            calendars = store.calendars(for: .event).filter {
                onlyCalendarIds.contains($0.calendarIdentifier)
            }
        }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        let ekEvents = store.events(matching: predicate)

        return ekEvents.compactMap { ek in
            // Skip all-day events
            guard !ek.isAllDay else { return nil }

            return CalendarEvent(
                id: "apple_\(ek.eventIdentifier ?? UUID().uuidString)",
                title: ek.title ?? "Untitled",
                startDate: ek.startDate,
                endDate: ek.endDate,
                location: ek.location,
                description: ek.notes,
                calendarName: ek.calendar.title
            )
        }
    }

    // MARK: - Types

    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        let accountName: String
        let color: CGColor?

        var displayName: String {
            "\(title) (\(accountName))"
        }
    }
}
