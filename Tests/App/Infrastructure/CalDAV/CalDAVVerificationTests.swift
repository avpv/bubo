import XCTest
@testable import Bubo

// MARK: - CalDAV Parsing + Ghost Computation Tests
//
// Covers the pure pieces of the CalDAV verification path: the
// multistatus XML parser (discovery + REPORT shapes), the iCalendar
// UID extractor (line folding, property parameters), and
// `CalDAVVerificationService.computeGhostKeys` — the comparison that
// decides which EventKit events the server no longer has. Network and
// timers are deliberately not exercised here; the client is a thin
// URLSession wrapper around these parsers.

final class CalDAVParsingTests: XCTestCase {

    // MARK: - UID extraction

    func testParseUIDsExtractsPlainAndParameterized() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-1@example.com
        SUMMARY:One
        END:VEVENT
        BEGIN:VEVENT
        UID;X-FOO=bar:event-2@example.com
        END:VEVENT
        END:VCALENDAR
        """
        XCTAssertEqual(
            CalDAVClient.parseUIDs(fromICS: ics),
            ["event-1@example.com", "event-2@example.com"]
        )
    }

    func testParseUIDsUnfoldsContinuationLines() {
        // RFC 5545 §3.1: a CRLF followed by space/tab continues the line.
        let ics = "BEGIN:VEVENT\r\nUID:very-long-\r\n uid-value@example.com\r\nEND:VEVENT"
        XCTAssertEqual(
            CalDAVClient.parseUIDs(fromICS: ics),
            ["very-long-uid-value@example.com"]
        )
    }

    func testParseUIDsIgnoresLookalikeProperties() {
        // Properties that merely start with the letters «UID» must not
        // match, nor should UID appear from SUMMARY text.
        let ics = """
        BEGIN:VEVENT
        UIDFAKE:nope
        SUMMARY:UID:not-a-uid
        UID:real@example.com
        END:VEVENT
        """
        XCTAssertEqual(CalDAVClient.parseUIDs(fromICS: ics), ["real@example.com"])
    }

    // MARK: - Multistatus parsing

    func testParsesPrincipalDiscoveryResponse() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/</D:href>
            <D:propstat>
              <D:prop>
                <D:current-user-principal>
                  <D:href>/principals/users/user%40yandex.ru/</D:href>
                </D:current-user-principal>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let responses = CalDAVMultiStatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.href, "/")
        XCTAssertEqual(responses.first?.principalHref, "/principals/users/user%40yandex.ru/")
    }

    func testParsesCalendarListingWithResourceTypes() {
        // Two collections: a real calendar and a plain folder — only the
        // one whose resourcetype carries <C:calendar/> counts.
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <D:response>
            <D:href>/calendars/user/events-123/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>Работа</D:displayname>
                <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
              </D:prop>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/calendars/user/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>Home folder</D:displayname>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let responses = CalDAVMultiStatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(responses.count, 2)
        let calendar = responses[0]
        XCTAssertTrue(calendar.isCalendar)
        XCTAssertEqual(calendar.displayName, "Работа")
        XCTAssertEqual(calendar.href, "/calendars/user/events-123/")
        XCTAssertFalse(responses[1].isCalendar)
    }

    func testParsesReportResponseCalendarData() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <D:response>
            <D:href>/calendars/user/events-123/abc.ics</D:href>
            <D:propstat>
              <D:prop>
                <C:calendar-data>BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:live-1@yandex.ru
        END:VEVENT
        END:VCALENDAR</C:calendar-data>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let responses = CalDAVMultiStatusParser.parse(Data(xml.utf8))
        let ics = responses.first?.calendarData
        XCTAssertNotNil(ics)
        XCTAssertEqual(CalDAVClient.parseUIDs(fromICS: ics ?? ""), ["live-1@yandex.ru"])
    }

    // MARK: - href resolution

    func testResolveHrefAgainstBase() {
        let base = URL(string: "https://caldav.yandex.ru")!
        XCTAssertEqual(
            CalDAVClient.resolve(href: "/calendars/u/events-1/", against: base)?.absoluteString,
            "https://caldav.yandex.ru/calendars/u/events-1/"
        )
        XCTAssertEqual(
            CalDAVClient.resolve(href: "https://other.example.com/cal/", against: base)?.absoluteString,
            "https://other.example.com/cal/"
        )
    }
}

// MARK: - Ghost computation

final class CalDAVGhostComputationTests: XCTestCase {

    private func key(
        id: String, series: String? = nil,
        calendar: String = "Работа", account: String = "Яндекс",
        uid: String? = nil
    ) -> ExternalEventSyncKey {
        ExternalEventSyncKey(
            occurrenceId: id, seriesKey: series,
            calendarTitle: calendar, accountName: account, uid: uid
        )
    }

    func testEventPresentOnServerIsNotGhost() {
        let ghosts = CalDAVVerificationService.computeGhostKeys(
            events: [key(id: "apple_a_1", uid: "a@y")],
            serverUIDsByCalendarTitle: ["Работа": ["a@y"]],
            accountName: "Яндекс"
        )
        XCTAssertTrue(ghosts.isEmpty)
    }

    func testEventMissingFromServerIsGhost() {
        let ghosts = CalDAVVerificationService.computeGhostKeys(
            events: [key(id: "apple_a_1", uid: "gone@y")],
            serverUIDsByCalendarTitle: ["Работа": ["other@y"]],
            accountName: "Яндекс"
        )
        XCTAssertEqual(ghosts, ["apple_a_1"])
    }

    func testRecurringGhostEmitsSeriesKey() {
        let ghosts = CalDAVVerificationService.computeGhostKeys(
            events: [key(id: "apple_s_1", series: "apple_s", uid: "gone@y")],
            serverUIDsByCalendarTitle: ["Работа": []],
            accountName: "Яндекс"
        )
        XCTAssertEqual(ghosts, ["apple_s"])
    }

    func testOtherAccountsAreNeverTouched() {
        // An iCloud calendar that happens to share the verified
        // calendar's title must not be compared against the server.
        let ghosts = CalDAVVerificationService.computeGhostKeys(
            events: [key(id: "apple_i_1", account: "iCloud", uid: "icloud-only@apple")],
            serverUIDsByCalendarTitle: ["Работа": []],
            accountName: "Яндекс"
        )
        XCTAssertTrue(ghosts.isEmpty)
    }

    func testUnfetchedCalendarIsSkipped() {
        // The event's calendar wasn't in the server result (fetch
        // failed or it only exists locally) — stay conservative.
        let ghosts = CalDAVVerificationService.computeGhostKeys(
            events: [key(id: "apple_a_1", calendar: "Личное", uid: "x@y")],
            serverUIDsByCalendarTitle: ["Работа": []],
            accountName: "Яндекс"
        )
        XCTAssertTrue(ghosts.isEmpty)
    }

    func testEventWithoutUIDIsSkipped() {
        let ghosts = CalDAVVerificationService.computeGhostKeys(
            events: [key(id: "apple_a_1", uid: nil)],
            serverUIDsByCalendarTitle: ["Работа": []],
            accountName: "Яндекс"
        )
        XCTAssertTrue(ghosts.isEmpty)
    }
}
