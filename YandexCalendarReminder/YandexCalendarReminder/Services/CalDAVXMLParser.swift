import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Proper XML parser for CalDAV multistatus responses
class CalDAVXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Calendar Discovery

    struct CalendarInfo {
        let href: String
        let displayName: String
        let isCalendar: Bool
    }

    func parseCalendars(from data: Data) -> [CalendarInfo] {
        calendars = []
        currentElement = ""
        currentHref = ""
        currentDisplayName = ""
        isInResourceType = false
        isCalendarType = false
        parseMode = .calendars

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()

        return calendars
    }

    // MARK: - Event Parsing

    func parseCalendarData(from data: Data) -> [String] {
        calendarDataEntries = []
        currentCalendarData = ""
        isInCalendarData = false
        parseMode = .events

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()

        return calendarDataEntries
    }

    // MARK: - Private State

    private enum ParseMode {
        case calendars
        case events
    }

    private var parseMode: ParseMode = .calendars

    // Calendar discovery state
    private var calendars: [CalendarInfo] = []
    private var currentElement = ""
    private var currentHref = ""
    private var currentDisplayName = ""
    private var isInResourceType = false
    private var isCalendarType = false
    private var isInResponse = false
    private var characterBuffer = ""

    // Event parsing state
    private var calendarDataEntries: [String] = []
    private var currentCalendarData = ""
    private var isInCalendarData = false

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        characterBuffer = ""
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch parseMode {
        case .calendars:
            switch localName {
            case "response":
                isInResponse = true
                currentHref = ""
                currentDisplayName = ""
                isCalendarType = false
            case "resourcetype":
                isInResourceType = true
            case "calendar" where isInResourceType:
                isCalendarType = true
            default:
                break
            }

        case .events:
            if localName == "calendar-data" {
                isInCalendarData = true
                currentCalendarData = ""
            }
        }

        currentElement = localName
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characterBuffer += string

        if parseMode == .events && isInCalendarData {
            currentCalendarData += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch parseMode {
        case .calendars:
            switch localName {
            case "href":
                if isInResponse {
                    currentHref = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "displayname":
                currentDisplayName = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "resourcetype":
                isInResourceType = false
            case "response":
                if isInResponse && !currentHref.isEmpty {
                    calendars.append(CalendarInfo(
                        href: currentHref,
                        displayName: currentDisplayName.isEmpty ? "Calendar" : currentDisplayName,
                        isCalendar: isCalendarType
                    ))
                }
                isInResponse = false
            default:
                break
            }

        case .events:
            if localName == "calendar-data" && isInCalendarData {
                let cleaned = currentCalendarData
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&amp;", with: "&")
                calendarDataEntries.append(cleaned)
                isInCalendarData = false
            }
        }

        characterBuffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Log but don't crash — partial results are still useful
        print("CalDAV XML parse error: \(parseError.localizedDescription)")
    }
}
