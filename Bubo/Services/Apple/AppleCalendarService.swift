import EventKit
import Foundation

/// Provides access to calendars configured in the native macOS Calendar.app
/// via EventKit. This includes iCloud, Exchange, Google, CalDAV, and any other
/// accounts the user has set up in System Settings → Internet Accounts.
///
/// Uses a shared EKEventStore instance and listens for external changes
/// (e.g. user edits in Calendar.app).
class AppleCalendarService {
    /// Shared event store — creating multiple instances is expensive and discouraged by Apple.
    static let shared = AppleCalendarService()

    private let store = EKEventStore()

    /// Posted when the underlying EKEventStore detects changes (events added/modified/deleted
    /// in Calendar.app or via iCloud sync). Observers should re-fetch events.
    static let calendarDataChanged = Notification.Name("AppleCalendarDataChanged")

    private var storeChangedObserver: Any?

    private init() {
        // Forward EKEventStoreChanged to our own notification on main queue
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: Self.calendarDataChanged, object: nil)
        }
    }

    deinit {
        if let observer = storeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Current authorization status for calendar access.
    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    static var hasAccess: Bool {
        let status = authorizationStatus
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    /// Request access to the user's calendars. Returns true if access was granted.
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                print("Failed to request full access: \(error)")
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

    /// List all calendars available in the system Calendar.app, grouped by source/account.
    func listCalendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                accountName: cal.source.title,
                sourceId: cal.source.sourceIdentifier,
                color: cal.cgColor
            )
        }
        .sorted { a, b in
            if a.accountName != b.accountName { return a.accountName < b.accountName }
            return a.title < b.title
        }
    }

    /// List calendars grouped by account name.
    func listCalendarsByAccount() -> [(account: String, calendars: [CalendarInfo])] {
        let all = listCalendars()
        let grouped = Dictionary(grouping: all) { $0.accountName }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (account: $0.key, calendars: $0.value) }
    }

    /// Fetch events from selected Apple calendars within a date range.
    func fetchEvents(from: Date, to: Date, onlyCalendarIds: [String] = []) -> [CalendarEvent] {
        // Ensure the store reflects the latest changes (deletions, edits) from
        // Calendar.app and remote sources (iCloud, Google, Exchange) before querying.
        store.refreshSourcesIfNecessary()

        let calendars: [EKCalendar]?
        if onlyCalendarIds.isEmpty {
            calendars = nil
        } else {
            calendars = store.calendars(for: .event).filter {
                onlyCalendarIds.contains($0.calendarIdentifier)
            }
        }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        let ekEvents = store.events(matching: predicate)

        return ekEvents.compactMap { ek in
            guard !ek.isAllDay else { return nil }
            
            let baseId = "apple_\(ek.eventIdentifier ?? UUID().uuidString)"
            let uniqueId = "\(baseId)_\(ek.startDate.timeIntervalSince1970)"

            return CalendarEvent(
                id: uniqueId,
                title: ek.title ?? "Untitled",
                startDate: ek.startDate,
                endDate: ek.endDate,
                location: ek.location,
                description: ek.notes,
                calendarName: ek.calendar.title,
                seriesId: ek.hasRecurrenceRules ? baseId : nil
            )
        }
    }

    /// Create a new event in Apple Calendar.
    /// - Parameters:
    ///   - event: The event data to create.
    ///   - calendarId: The calendar identifier to add the event to. Uses the default calendar if nil.
    func createEvent(_ event: CalendarEvent, calendarId: String? = nil) throws {
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate
        ekEvent.location = event.location
        ekEvent.notes = event.description
        if let calendarId,
           let calendar = store.calendars(for: .event).first(where: { $0.calendarIdentifier == calendarId }) {
            ekEvent.calendar = calendar
        } else {
            ekEvent.calendar = store.defaultCalendarForNewEvents
        }
        try store.save(ekEvent, span: .thisEvent)
    }

    /// The identifier of the default calendar for new events, if available.
    var defaultCalendarId: String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    /// Shift the start and end times of an Apple Calendar event by a given number of minutes.
    func shiftEventTime(id: String, byMinutes minutes: Int) throws {
        var actualId = id.replacingOccurrences(of: "apple_", with: "")
        if let lastUnderscore = actualId.lastIndex(of: "_") {
            // Strip the timestamp we added to make it unique per occurrence
            actualId = String(actualId[..<lastUnderscore])
        }
        
        guard let ekEvent = store.event(withIdentifier: actualId) else {
            throw NSError(domain: "AppleCalendarService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Event not found."])
        }
        let interval = TimeInterval(minutes * 60)
        ekEvent.startDate = ekEvent.startDate.addingTimeInterval(interval)
        ekEvent.endDate = ekEvent.endDate.addingTimeInterval(interval)
        try store.save(ekEvent, span: .thisEvent)
    }

    // MARK: - Types

    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        let accountName: String
        let sourceId: String
        let color: CGColor?

        var displayName: String {
            title
        }
    }
}
