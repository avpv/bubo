import Foundation

/// Google Calendar API v3 service
actor GoogleCalendarService {
    private let baseURL = AppConfig.googleCalendarBaseURL

    struct CalendarListResponse: Codable {
        let items: [CalendarListEntry]
    }

    struct CalendarListEntry: Codable {
        let id: String
        let summary: String
        let primary: Bool?
    }

    struct EventsResponse: Codable {
        let items: [GoogleEvent]?
        let nextPageToken: String?
    }

    struct GoogleEvent: Codable {
        let id: String
        let summary: String?
        let start: GoogleDateTime?
        let end: GoogleDateTime?
        let location: String?
        let description: String?
        let status: String?
        let recurrence: [String]?
    }

    struct GoogleDateTime: Codable {
        let dateTime: String?  // RFC 3339 for timed events
        let date: String?      // yyyy-MM-dd for all-day events
        let timeZone: String?
    }

    // MARK: - Public API

    func listCalendars() async throws -> [CalendarListEntry] {
        let data = try await authenticatedRequest(path: "/users/me/calendarList")
        let response = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        return response.items
    }

    func fetchEvents(
        from startDate: Date,
        to endDate: Date,
        onlyCalendarIds: [String] = []
    ) async throws -> [CalendarEvent] {
        let calendars = try await listCalendars()

        var allEvents: [CalendarEvent] = []
        for calendar in calendars {
            if !onlyCalendarIds.isEmpty && !onlyCalendarIds.contains(calendar.id) {
                continue
            }

            let events = try await fetchEventsFromCalendar(
                calendarId: calendar.id,
                calendarName: calendar.summary,
                from: startDate,
                to: endDate
            )
            allEvents.append(contentsOf: events)
        }

        return allEvents.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Private

    private func fetchEventsFromCalendar(
        calendarId: String,
        calendarName: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [CalendarEvent] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let encodedId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let path = "/calendars/\(encodedId)/events"

        let queryItems = [
            "timeMin=\(isoFormatter.string(from: startDate))",
            "timeMax=\(isoFormatter.string(from: endDate))",
            "singleEvents=true",     // Expand recurring events
            "orderBy=startTime",
            "maxResults=250"
        ].joined(separator: "&")

        let data = try await authenticatedRequest(path: path, query: queryItems)
        let response = try JSONDecoder().decode(EventsResponse.self, from: data)

        return (response.items ?? []).compactMap { event in
            convertToCalendarEvent(event, calendarName: calendarName)
        }
    }

    private func convertToCalendarEvent(_ event: GoogleEvent, calendarName: String) -> CalendarEvent? {
        // Skip cancelled events
        if event.status == "cancelled" { return nil }

        guard let summary = event.summary,
              let start = event.start,
              let startDate = parseGoogleDateTime(start) else {
            return nil
        }

        let endDate: Date
        if let end = event.end, let parsed = parseGoogleDateTime(end) {
            endDate = parsed
        } else {
            endDate = startDate.addingTimeInterval(3600)
        }

        return CalendarEvent(
            id: "google_\(event.id)",
            title: summary,
            startDate: startDate,
            endDate: endDate,
            location: event.location,
            description: event.description,
            calendarName: calendarName
        )
    }

    private func parseGoogleDateTime(_ dt: GoogleDateTime) -> Date? {
        if let dateTimeStr = dt.dateTime {
            // RFC 3339 format: 2024-01-15T10:00:00+03:00
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: dateTimeStr)
        }

        if let dateStr = dt.date {
            // All-day: 2024-01-15
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = dt.timeZone.flatMap { TimeZone(identifier: $0) } ?? .current
            return formatter.date(from: dateStr)
        }

        return nil
    }

    private func authenticatedRequest(path: String, query: String? = nil) async throws -> Data {
        let token = try await GoogleOAuthService.getValidAccessToken()

        var urlString = baseURL + path
        if let query = query {
            urlString += "?\(query)"
        }

        guard let url = URL(string: urlString) else {
            throw GoogleCalendarError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw GoogleCalendarError.httpError(httpResponse.statusCode)
        }

        return data
    }
}

enum GoogleCalendarError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Google Calendar URL"
        case .invalidResponse: return "Invalid Google response"
        case .httpError(let code):
            switch code {
            case 401: return "Google authorization error. Please re-authenticate"
            case 403: return "Google Calendar access denied"
            case 429: return "Too many requests to Google"
            default: return "Google API error: \(code)"
            }
        }
    }
}
