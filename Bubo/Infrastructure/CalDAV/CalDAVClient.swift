import Foundation

// MARK: - CalDAV Client
//
// Minimal CalDAV read path used by `CalDAVVerificationService` to ask
// the calendar server which events actually exist. This is NOT a sync
// engine: it performs the standard three-step discovery (RFC 4791/5397
// — current-user-principal → calendar-home-set → depth-1 listing) and
// one `calendar-query` REPORT per calendar to collect the UIDs of
// events overlapping a time window. Read-only, Basic-auth, no state.
//
// Exists because macOS's own CalDAV sync can wedge: a server whose
// incremental sync never propagates deletions (Yandex Calendar is a
// known offender) leaves ghost events in the local EventKit database,
// and EventKit offers no way to force a deeper refresh. Comparing
// EventKit's UIDs against the server's ground truth is the only way a
// third-party app can detect those ghosts.

// MARK: Types

/// One calendar collection discovered on the server.
struct CalDAVCalendar: Equatable, Sendable {
    /// Collection href as returned by the server (usually an absolute
    /// path like `/calendars/user%40example.com/events-123/`).
    let href: String
    /// Human-readable name — matched against `EKCalendar.title`.
    let displayName: String
}

enum CalDAVError: Error, LocalizedError {
    case badURL
    case httpStatus(Int)
    case principalNotFound
    case calendarHomeNotFound

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server URL"
        case .httpStatus(let code): return "Server returned HTTP \(code)"
        case .principalNotFound: return "Could not discover the account principal (check the URL and credentials)"
        case .calendarHomeNotFound: return "Could not discover the calendar home (check the URL and credentials)"
        }
    }
}

/// Abstraction so `CalDAVVerificationService` can be driven with a fake
/// in tests — no network, canned calendars and UID sets.
protocol CalDAVFetching: Sendable {
    /// Discover the account's calendar collections.
    func discoverCalendars(
        baseURL: URL, username: String, password: String
    ) async throws -> [CalDAVCalendar]

    /// UIDs of every VEVENT overlapping [from, to] in one calendar.
    func fetchEventUIDs(
        calendar: CalDAVCalendar, baseURL: URL,
        username: String, password: String,
        from: Date, to: Date
    ) async throws -> Set<String>
}

// MARK: Client

final class CalDAVClient: CalDAVFetching {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Discovery

    func discoverCalendars(
        baseURL: URL, username: String, password: String
    ) async throws -> [CalDAVCalendar] {
        // 1. Where is «me»?
        let principalResponses = try await propfind(
            url: baseURL, depth: "0",
            props: "<D:current-user-principal/>",
            username: username, password: password
        )
        guard
            let principalHref = principalResponses.compactMap(\.principalHref).first,
            let principalURL = Self.resolve(href: principalHref, against: baseURL)
        else { throw CalDAVError.principalNotFound }

        // 2. Where do my calendars live?
        let homeResponses = try await propfind(
            url: principalURL, depth: "0",
            props: "<C:calendar-home-set/>",
            username: username, password: password
        )
        guard
            let homeHref = homeResponses.compactMap(\.calendarHomeHref).first,
            let homeURL = Self.resolve(href: homeHref, against: baseURL)
        else { throw CalDAVError.calendarHomeNotFound }

        // 3. List the collections; keep only actual calendars.
        let listing = try await propfind(
            url: homeURL, depth: "1",
            props: "<D:displayname/><D:resourcetype/>",
            username: username, password: password
        )
        return listing.compactMap { response in
            guard response.isCalendar,
                  let name = response.displayName, !name.isEmpty,
                  !response.href.isEmpty
            else { return nil }
            return CalDAVCalendar(href: response.href, displayName: name)
        }
    }

    // MARK: Event UIDs

    func fetchEventUIDs(
        calendar: CalDAVCalendar, baseURL: URL,
        username: String, password: String,
        from: Date, to: Date
    ) async throws -> Set<String> {
        guard let calendarURL = Self.resolve(href: calendar.href, against: baseURL) else {
            throw CalDAVError.badURL
        }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <D:prop><C:calendar-data/></D:prop>
          <C:filter>
            <C:comp-filter name="VCALENDAR">
              <C:comp-filter name="VEVENT">
                <C:time-range start="\(Self.queryDateFormatter.string(from: from))" end="\(Self.queryDateFormatter.string(from: to))"/>
              </C:comp-filter>
            </C:comp-filter>
          </C:filter>
        </C:calendar-query>
        """
        let data = try await perform(
            url: calendarURL, method: "REPORT", depth: "1", body: body,
            username: username, password: password
        )
        let responses = CalDAVMultiStatusParser.parse(data)
        var uids: Set<String> = []
        for response in responses {
            if let ics = response.calendarData {
                uids.formUnion(Self.parseUIDs(fromICS: ics))
            }
        }
        return uids
    }

    // MARK: Requests

    private func propfind(
        url: URL, depth: String, props: String,
        username: String, password: String
    ) async throws -> [CalDAVMultiStatusParser.Response] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <D:prop>\(props)</D:prop>
        </D:propfind>
        """
        let data = try await perform(
            url: url, method: "PROPFIND", depth: depth, body: body,
            username: username, password: password
        )
        return CalDAVMultiStatusParser.parse(data)
    }

    private func perform(
        url: URL, method: String, depth: String, body: String,
        username: String, password: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = Data(body.utf8)
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CalDAVError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: Pure helpers (static — unit-testable without network)

    /// Resolve a DAV `href` (usually an absolute path, sometimes a full
    /// URL) against the configured base URL.
    static func resolve(href: String, against baseURL: URL) -> URL? {
        URL(string: href, relativeTo: baseURL)?.absoluteURL
    }

    /// CalDAV `time-range` timestamp format (UTC, RFC 4791 §9.9).
    static let queryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// Extract every `UID` value from raw iCalendar text. Unfolds
    /// continuation lines first (RFC 5545 §3.1: CRLF followed by a
    /// space or tab continues the previous line) and accepts optional
    /// property parameters (`UID;X=Y:value`).
    static func parseUIDs(fromICS ics: String) -> Set<String> {
        let unfolded = ics
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        var uids: Set<String> = []
        for line in unfolded.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("UID") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
            guard name == "UID" || name.hasPrefix("UID;") else { continue }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { uids.insert(value) }
        }
        return uids
    }
}

// MARK: - Multistatus Parser

/// Small `XMLParser` delegate for WebDAV 207 multistatus bodies. Namespace
/// -aware (`shouldProcessNamespaces`), so element names arrive without
/// prefixes regardless of how the server spells `D:`/`C:`. Collects, per
/// `<response>`: the resource href, `displayname`, inline `calendar-data`,
/// whether the resourcetype marks a calendar collection, and the two
/// discovery hrefs (`current-user-principal`, `calendar-home-set`).
final class CalDAVMultiStatusParser: NSObject, XMLParserDelegate {

    struct Response {
        var href: String = ""
        var displayName: String?
        var calendarData: String?
        var isCalendar: Bool = false
        var principalHref: String?
        var calendarHomeHref: String?
    }

    private var responses: [Response] = []
    private var current: Response?
    private var stack: [String] = []
    private var textBuffer = ""

    static func parse(_ data: Data) -> [Response] {
        let delegate = CalDAVMultiStatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.responses
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = elementName.lowercased()
        stack.append(name)
        textBuffer = ""
        if name == "response" {
            current = Response()
        } else if name == "calendar", stack.contains("resourcetype") {
            current?.isCalendar = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        textBuffer += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let parents = stack.dropLast()

        switch name {
        case "href":
            if parents.contains("current-user-principal") {
                current?.principalHref = text
            } else if parents.contains("calendar-home-set") {
                current?.calendarHomeHref = text
            } else if parents.last == "response", current?.href.isEmpty == true {
                current?.href = text
            }
        case "displayname":
            if !text.isEmpty { current?.displayName = text }
        case "calendar-data":
            if !text.isEmpty { current?.calendarData = text }
        case "response":
            if let finished = current { responses.append(finished) }
            current = nil
        default:
            break
        }

        stack.removeLast()
        textBuffer = ""
    }
}
