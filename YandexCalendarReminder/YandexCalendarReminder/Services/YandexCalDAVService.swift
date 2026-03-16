import Foundation

actor YandexCalDAVService {
    private let baseURL = "https://caldav.yandex.ru"

    enum AuthMode {
        case appPassword(login: String, password: String)
        case oauth
    }

    private var authMode: AuthMode

    init(authMode: AuthMode) {
        self.authMode = authMode
    }

    func updateAuthMode(_ mode: AuthMode) {
        self.authMode = mode
    }

    func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEvent] {
        let login = try await resolveLogin()
        let calendarsPath = "/calendars/\(login)/"

        let calendarInfos = try await RetryHelper.withRetry {
            try await self.discoverCalendars(path: calendarsPath)
        }

        var allEvents: [CalendarEvent] = []
        for info in calendarInfos where info.isCalendar {
            let events = try await RetryHelper.withRetry {
                try await self.fetchEventsFromCalendar(
                    path: info.href,
                    calendarName: info.displayName,
                    from: startDate,
                    to: endDate
                )
            }
            allEvents.append(contentsOf: events)
        }

        return allEvents.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Private

    private func resolveLogin() async throws -> String {
        switch authMode {
        case .appPassword(let login, _):
            return login
        case .oauth:
            // For OAuth, we need the login stored in Keychain
            guard let login = KeychainService.load(.yandexLogin) else {
                throw CalDAVError.invalidURL
            }
            return login
        }
    }

    private func discoverCalendars(path: String) async throws -> [CalDAVXMLParser.CalendarInfo] {
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
        let parser = CalDAVXMLParser()
        let calendars = parser.parseCalendars(from: data)

        // Filter out the parent path itself
        return calendars.filter { $0.isCalendar && $0.href != path }
    }

    private func fetchEventsFromCalendar(
        path: String,
        calendarName: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [CalendarEvent] {
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

        let xmlParser = CalDAVXMLParser()
        let icalEntries = xmlParser.parseCalendarData(from: data)

        var events: [CalendarEvent] = []
        for ical in icalEntries {
            let parsed = ICalParser.parseEvents(
                ical,
                calendarName: calendarName,
                expandFrom: startDate,
                expandTo: endDate
            )
            events.append(contentsOf: parsed)
        }

        return events
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
        request.timeoutInterval = 30

        // Set auth header based on mode
        switch authMode {
        case .appPassword(let login, let password):
            let credentials = "\(login):\(password)"
            if let credData = credentials.data(using: .utf8) {
                request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        case .oauth:
            let token = try await YandexOAuthService.getValidAccessToken()
            request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
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
        case .httpError(let code):
            switch code {
            case 401: return "Ошибка авторизации. Проверьте учётные данные"
            case 403: return "Доступ запрещён"
            case 404: return "Календарь не найден"
            case 500...599: return "Ошибка сервера Яндекса (\(code))"
            default: return "Ошибка HTTP: \(code)"
            }
        case .parseError: return "Ошибка разбора данных"
        }
    }
}
