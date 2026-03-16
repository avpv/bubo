import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

actor YandexCalDAVService {
    private let baseURL = "https://caldav.yandex.ru"
    private var login: String
    private var appPassword: String

    init(login: String, appPassword: String) {
        self.login = login
        self.appPassword = appPassword
    }

    func updateCredentials(login: String, appPassword: String) {
        self.login = login
        self.appPassword = appPassword
    }

    func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEvent] {
        let calendarsPath = "/calendars/\(login)/"

        // Step 1: Discover calendars
        let calendarURLs = try await discoverCalendars(path: calendarsPath)

        // Step 2: Fetch events from each calendar
        var allEvents: [CalendarEvent] = []
        for (calendarURL, calendarName) in calendarURLs {
            let events = try await fetchEventsFromCalendar(
                path: calendarURL,
                calendarName: calendarName,
                from: startDate,
                to: endDate
            )
            allEvents.append(contentsOf: events)
        }

        return allEvents.sorted { $0.startDate < $1.startDate }
    }

    private func discoverCalendars(path: String) async throws -> [(String, String)] {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:prop>
                <d:displayname/>
                <d:resourcetype/>
            </d:prop>
        </d:propfind>
        """

        let (data, _) = try await sendRequest(method: "PROPFIND", path: path, body: body, depth: "1")
        return parseCalendarList(data: data)
    }

    private func fetchEventsFromCalendar(
        path: String,
        calendarName: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [CalendarEvent] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]

        let startStr = formatCalDAVDate(startDate)
        let endStr = formatCalDAVDate(endDate)

        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:prop>
                <d:getetag/>
                <c:calendar-data/>
            </d:prop>
            <c:filter>
                <c:comp-filter name="VCALENDAR">
                    <c:comp-filter name="VEVENT">
                        <c:time-range start="\(startStr)" end="\(endStr)"/>
                    </c:comp-filter>
                </c:comp-filter>
            </c:filter>
        </c:calendar-query>
        """

        let (data, _) = try await sendRequest(method: "REPORT", path: path, body: body, depth: "1")
        return parseEvents(data: data, calendarName: calendarName)
    }

    private func formatCalDAVDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func sendRequest(
        method: String,
        path: String,
        body: String,
        depth: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.httpBody = body.data(using: .utf8)

        // Basic auth
        let credentials = "\(login):\(appPassword)"
        if let credData = credentials.data(using: .utf8) {
            let base64 = credData.base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207 else {
            throw CalDAVError.httpError(httpResponse.statusCode)
        }

        return (data, httpResponse)
    }

    private func parseCalendarList(data: Data) -> [(String, String)] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [] }

        var calendars: [(String, String)] = []
        // Simple XML parsing for calendar discovery
        let responses = xmlString.components(separatedBy: "<d:response>")

        for response in responses.dropFirst() {
            guard let hrefStart = response.range(of: "<d:href>"),
                  let hrefEnd = response.range(of: "</d:href>") else { continue }

            let href = String(response[hrefStart.upperBound..<hrefEnd.lowerBound])

            // Check if it's a calendar (has <c:calendar/> or <cal:calendar/> in resourcetype)
            let isCalendar = response.contains("calendar")
                && response.contains("resourcetype")
                && !href.hasSuffix(".ics")

            if isCalendar && href != "/calendars/\(login)/" {
                var displayName = "Calendar"
                if let nameStart = response.range(of: "<d:displayname>"),
                   let nameEnd = response.range(of: "</d:displayname>") {
                    displayName = String(response[nameStart.upperBound..<nameEnd.lowerBound])
                }
                calendars.append((href, displayName))
            }
        }

        return calendars
    }

    private func parseEvents(data: Data, calendarName: String) -> [CalendarEvent] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [] }

        var events: [CalendarEvent] = []
        let responses = xmlString.components(separatedBy: "<d:response>")

        for response in responses.dropFirst() {
            // Extract calendar-data (iCal content)
            guard let calDataStart = response.range(of: "<c:calendar-data>") ?? response.range(of: "<cal:calendar-data>"),
                  let calDataEnd = response.range(of: "</c:calendar-data>") ?? response.range(of: "</cal:calendar-data>") else {
                continue
            }

            let icalData = String(response[calDataStart.upperBound..<calDataEnd.lowerBound])
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")

            if let event = parseICalEvent(icalData, calendarName: calendarName) {
                events.append(event)
            }
        }

        return events
    }

    private func parseICalEvent(_ ical: String, calendarName: String) -> CalendarEvent? {
        let lines = ical.components(separatedBy: .newlines)

        var uid: String?
        var summary: String?
        var dtstart: Date?
        var dtend: Date?
        var location: String?
        var description: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("UID:") {
                uid = String(trimmed.dropFirst(4))
            } else if trimmed.hasPrefix("SUMMARY:") {
                summary = String(trimmed.dropFirst(8))
            } else if trimmed.hasPrefix("DTSTART") {
                dtstart = parseICalDate(trimmed)
            } else if trimmed.hasPrefix("DTEND") {
                dtend = parseICalDate(trimmed)
            } else if trimmed.hasPrefix("LOCATION:") {
                location = String(trimmed.dropFirst(9))
            } else if trimmed.hasPrefix("DESCRIPTION:") {
                description = String(trimmed.dropFirst(12))
            }
        }

        guard let id = uid, let title = summary, let start = dtstart else {
            return nil
        }

        return CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: dtend ?? start.addingTimeInterval(3600),
            location: location,
            description: description,
            calendarName: calendarName
        )
    }

    private func parseICalDate(_ line: String) -> Date? {
        // Handle formats like DTSTART;TZID=Europe/Moscow:20240101T120000
        // or DTSTART:20240101T120000Z
        // or DTSTART;VALUE=DATE:20240101
        let parts = line.components(separatedBy: ":")
        guard let dateStr = parts.last else { return nil }

        var tzIdentifier: String?
        if line.contains("TZID=") {
            if let tzRange = line.range(of: "TZID=") {
                let afterTZ = line[tzRange.upperBound...]
                if let colonRange = afterTZ.range(of: ":") {
                    tzIdentifier = String(afterTZ[..<colonRange.lowerBound])
                }
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if dateStr.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else if dateStr.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = tzIdentifier.flatMap { TimeZone(identifier: $0) } ?? .current
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = tzIdentifier.flatMap { TimeZone(identifier: $0) } ?? .current
        }

        return formatter.date(from: dateStr)
    }
}

enum CalDAVError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Неверный URL"
        case .invalidResponse: return "Некорректный ответ сервера"
        case .httpError(let code): return "Ошибка HTTP: \(code)"
        case .parseError: return "Ошибка разбора данных"
        }
    }
}
