import SwiftUI
import BuboDomain

// MARK: - World Clock City

struct WorldClockCity: Identifiable, Codable, Hashable {
    var id: String { "\(city)_\(timezoneID)" }
    let timezoneID: String
    let city: String
    let country: String

    var timeZone: TimeZone? {
        TimeZone(identifier: timezoneID)
    }

    var displayName: String {
        "\(city), \(country)"
    }

    /// All available cities grouped for the picker.
    static let allCities: [WorldClockCity] = [
        // UTC
        WorldClockCity(timezoneID: "UTC", city: "UTC", country: "Coordinated Universal Time"),

        // Americas
        WorldClockCity(timezoneID: "America/New_York", city: "New York", country: "U.S.A."),
        WorldClockCity(timezoneID: "America/Chicago", city: "Chicago", country: "U.S.A."),
        WorldClockCity(timezoneID: "America/Denver", city: "Denver", country: "U.S.A."),
        WorldClockCity(timezoneID: "America/Los_Angeles", city: "Los Angeles", country: "U.S.A."),
        WorldClockCity(timezoneID: "America/Anchorage", city: "Anchorage", country: "U.S.A."),
        WorldClockCity(timezoneID: "Pacific/Honolulu", city: "Honolulu", country: "U.S.A."),
        WorldClockCity(timezoneID: "America/Puerto_Rico", city: "San Juan", country: "Puerto Rico"),
        WorldClockCity(timezoneID: "America/Toronto", city: "Toronto", country: "Canada"),
        WorldClockCity(timezoneID: "America/Vancouver", city: "Vancouver", country: "Canada"),
        WorldClockCity(timezoneID: "America/Edmonton", city: "Edmonton", country: "Canada"),
        WorldClockCity(timezoneID: "America/Mexico_City", city: "Mexico City", country: "Mexico"),
        WorldClockCity(timezoneID: "America/Sao_Paulo", city: "Sao Paulo", country: "Brazil"),
        WorldClockCity(timezoneID: "America/Argentina/Buenos_Aires", city: "Buenos Aires", country: "Argentina"),
        WorldClockCity(timezoneID: "America/Bogota", city: "Bogota", country: "Colombia"),
        WorldClockCity(timezoneID: "America/Lima", city: "Lima", country: "Peru"),
        WorldClockCity(timezoneID: "America/Santiago", city: "Santiago", country: "Chile"),
        WorldClockCity(timezoneID: "America/Montevideo", city: "Montevideo", country: "Uruguay"),
        WorldClockCity(timezoneID: "America/Caracas", city: "Caracas", country: "Venezuela"),
        WorldClockCity(timezoneID: "America/Guayaquil", city: "Quito", country: "Ecuador"),
        WorldClockCity(timezoneID: "America/Havana", city: "Havana", country: "Cuba"),
        WorldClockCity(timezoneID: "America/Panama", city: "Panama City", country: "Panama"),
        WorldClockCity(timezoneID: "America/Santo_Domingo", city: "Santo Domingo", country: "Dominican Republic"),
        WorldClockCity(timezoneID: "America/Costa_Rica", city: "San Jose", country: "Costa Rica"),

        // Europe
        WorldClockCity(timezoneID: "Europe/London", city: "London", country: "U.K."),
        WorldClockCity(timezoneID: "Europe/Paris", city: "Paris", country: "France"),
        WorldClockCity(timezoneID: "Europe/Berlin", city: "Berlin", country: "Germany"),
        WorldClockCity(timezoneID: "Europe/Madrid", city: "Madrid", country: "Spain"),
        WorldClockCity(timezoneID: "Europe/Rome", city: "Rome", country: "Italy"),
        WorldClockCity(timezoneID: "Europe/Amsterdam", city: "Amsterdam", country: "Netherlands"),
        WorldClockCity(timezoneID: "Europe/Brussels", city: "Brussels", country: "Belgium"),
        WorldClockCity(timezoneID: "Europe/Luxembourg", city: "Luxembourg", country: "Luxembourg"),
        WorldClockCity(timezoneID: "Europe/Zurich", city: "Zurich", country: "Switzerland"),
        WorldClockCity(timezoneID: "Europe/Stockholm", city: "Stockholm", country: "Sweden"),
        WorldClockCity(timezoneID: "Europe/Oslo", city: "Oslo", country: "Norway"),
        WorldClockCity(timezoneID: "Europe/Copenhagen", city: "Copenhagen", country: "Denmark"),
        WorldClockCity(timezoneID: "Europe/Helsinki", city: "Helsinki", country: "Finland"),
        WorldClockCity(timezoneID: "Atlantic/Reykjavik", city: "Reykjavik", country: "Iceland"),
        WorldClockCity(timezoneID: "Europe/Warsaw", city: "Warsaw", country: "Poland"),
        WorldClockCity(timezoneID: "Europe/Prague", city: "Prague", country: "Czech Republic"),
        WorldClockCity(timezoneID: "Europe/Bratislava", city: "Bratislava", country: "Slovakia"),
        WorldClockCity(timezoneID: "Europe/Vienna", city: "Vienna", country: "Austria"),
        WorldClockCity(timezoneID: "Europe/Budapest", city: "Budapest", country: "Hungary"),
        WorldClockCity(timezoneID: "Europe/Belgrade", city: "Belgrade", country: "Serbia"),
        WorldClockCity(timezoneID: "Europe/Zagreb", city: "Zagreb", country: "Croatia"),
        WorldClockCity(timezoneID: "Europe/Ljubljana", city: "Ljubljana", country: "Slovenia"),
        WorldClockCity(timezoneID: "Europe/Sarajevo", city: "Sarajevo", country: "Bosnia and Herzegovina"),
        WorldClockCity(timezoneID: "Europe/Podgorica", city: "Podgorica", country: "Montenegro"),
        WorldClockCity(timezoneID: "Europe/Skopje", city: "Skopje", country: "North Macedonia"),
        WorldClockCity(timezoneID: "Europe/Tirane", city: "Tirana", country: "Albania"),
        WorldClockCity(timezoneID: "Europe/Athens", city: "Athens", country: "Greece"),
        WorldClockCity(timezoneID: "Europe/Bucharest", city: "Bucharest", country: "Romania"),
        WorldClockCity(timezoneID: "Europe/Sofia", city: "Sofia", country: "Bulgaria"),
        WorldClockCity(timezoneID: "Europe/Istanbul", city: "Istanbul", country: "Turkey"),
        WorldClockCity(timezoneID: "Asia/Nicosia", city: "Nicosia", country: "Cyprus"),
        WorldClockCity(timezoneID: "Europe/Moscow", city: "Moscow", country: "Russia"),
        WorldClockCity(timezoneID: "Europe/Kiev", city: "Kyiv", country: "Ukraine"),
        WorldClockCity(timezoneID: "Europe/Minsk", city: "Minsk", country: "Belarus"),
        WorldClockCity(timezoneID: "Europe/Tallinn", city: "Tallinn", country: "Estonia"),
        WorldClockCity(timezoneID: "Europe/Riga", city: "Riga", country: "Latvia"),
        WorldClockCity(timezoneID: "Europe/Vilnius", city: "Vilnius", country: "Lithuania"),
        WorldClockCity(timezoneID: "Europe/Chisinau", city: "Chisinau", country: "Moldova"),
        WorldClockCity(timezoneID: "Europe/Dublin", city: "Dublin", country: "Ireland"),
        WorldClockCity(timezoneID: "Europe/Lisbon", city: "Lisbon", country: "Portugal"),

        // Asia
        WorldClockCity(timezoneID: "Asia/Tokyo", city: "Tokyo", country: "Japan"),
        WorldClockCity(timezoneID: "Asia/Shanghai", city: "Shanghai", country: "China"),
        WorldClockCity(timezoneID: "Asia/Hong_Kong", city: "Hong Kong", country: "China"),
        WorldClockCity(timezoneID: "Asia/Seoul", city: "Seoul", country: "South Korea"),
        WorldClockCity(timezoneID: "Asia/Kolkata", city: "Mumbai", country: "India"),
        WorldClockCity(timezoneID: "Asia/Kolkata", city: "New Delhi", country: "India"),
        WorldClockCity(timezoneID: "Asia/Singapore", city: "Singapore", country: "Singapore"),
        WorldClockCity(timezoneID: "Asia/Bangkok", city: "Bangkok", country: "Thailand"),
        WorldClockCity(timezoneID: "Asia/Dubai", city: "Dubai", country: "UAE"),
        WorldClockCity(timezoneID: "Asia/Qatar", city: "Doha", country: "Qatar"),
        WorldClockCity(timezoneID: "Asia/Muscat", city: "Muscat", country: "Oman"),
        WorldClockCity(timezoneID: "Asia/Kuwait", city: "Kuwait City", country: "Kuwait"),
        WorldClockCity(timezoneID: "Asia/Riyadh", city: "Riyadh", country: "Saudi Arabia"),
        WorldClockCity(timezoneID: "Asia/Taipei", city: "Taipei", country: "Taiwan"),
        WorldClockCity(timezoneID: "Asia/Jakarta", city: "Jakarta", country: "Indonesia"),
        WorldClockCity(timezoneID: "Asia/Karachi", city: "Karachi", country: "Pakistan"),
        WorldClockCity(timezoneID: "Asia/Dhaka", city: "Dhaka", country: "Bangladesh"),
        WorldClockCity(timezoneID: "Asia/Kuala_Lumpur", city: "Kuala Lumpur", country: "Malaysia"),
        WorldClockCity(timezoneID: "Asia/Manila", city: "Manila", country: "Philippines"),
        WorldClockCity(timezoneID: "Asia/Ho_Chi_Minh", city: "Ho Chi Minh", country: "Vietnam"),
        WorldClockCity(timezoneID: "Asia/Phnom_Penh", city: "Phnom Penh", country: "Cambodia"),
        WorldClockCity(timezoneID: "Asia/Yangon", city: "Yangon", country: "Myanmar"),
        WorldClockCity(timezoneID: "Asia/Kathmandu", city: "Kathmandu", country: "Nepal"),
        WorldClockCity(timezoneID: "Asia/Colombo", city: "Colombo", country: "Sri Lanka"),
        WorldClockCity(timezoneID: "Asia/Almaty", city: "Almaty", country: "Kazakhstan"),
        WorldClockCity(timezoneID: "Asia/Tashkent", city: "Tashkent", country: "Uzbekistan"),
        WorldClockCity(timezoneID: "Asia/Tbilisi", city: "Tbilisi", country: "Georgia"),
        WorldClockCity(timezoneID: "Asia/Yerevan", city: "Yerevan", country: "Armenia"),
        WorldClockCity(timezoneID: "Asia/Baku", city: "Baku", country: "Azerbaijan"),
        WorldClockCity(timezoneID: "Asia/Tehran", city: "Tehran", country: "Iran"),
        WorldClockCity(timezoneID: "Asia/Jerusalem", city: "Jerusalem", country: "Israel"),
        WorldClockCity(timezoneID: "Asia/Beirut", city: "Beirut", country: "Lebanon"),
        WorldClockCity(timezoneID: "Asia/Amman", city: "Amman", country: "Jordan"),
        WorldClockCity(timezoneID: "Asia/Baghdad", city: "Baghdad", country: "Iraq"),

        // Africa
        WorldClockCity(timezoneID: "Africa/Cairo", city: "Cairo", country: "Egypt"),
        WorldClockCity(timezoneID: "Africa/Lagos", city: "Lagos", country: "Nigeria"),
        WorldClockCity(timezoneID: "Africa/Johannesburg", city: "Johannesburg", country: "South Africa"),
        WorldClockCity(timezoneID: "Africa/Nairobi", city: "Nairobi", country: "Kenya"),
        WorldClockCity(timezoneID: "Africa/Casablanca", city: "Casablanca", country: "Morocco"),
        WorldClockCity(timezoneID: "Africa/Addis_Ababa", city: "Addis Ababa", country: "Ethiopia"),
        WorldClockCity(timezoneID: "Africa/Accra", city: "Accra", country: "Ghana"),
        WorldClockCity(timezoneID: "Africa/Dar_es_Salaam", city: "Dar es Salaam", country: "Tanzania"),
        WorldClockCity(timezoneID: "Africa/Tunis", city: "Tunis", country: "Tunisia"),
        WorldClockCity(timezoneID: "Africa/Algiers", city: "Algiers", country: "Algeria"),
        WorldClockCity(timezoneID: "Africa/Kinshasa", city: "Kinshasa", country: "DR Congo"),
        WorldClockCity(timezoneID: "Africa/Luanda", city: "Luanda", country: "Angola"),
        WorldClockCity(timezoneID: "Africa/Kampala", city: "Kampala", country: "Uganda"),

        // Oceania
        WorldClockCity(timezoneID: "Australia/Sydney", city: "Sydney", country: "Australia"),
        WorldClockCity(timezoneID: "Australia/Melbourne", city: "Melbourne", country: "Australia"),
        WorldClockCity(timezoneID: "Australia/Brisbane", city: "Brisbane", country: "Australia"),
        WorldClockCity(timezoneID: "Australia/Adelaide", city: "Adelaide", country: "Australia"),
        WorldClockCity(timezoneID: "Australia/Perth", city: "Perth", country: "Australia"),
        WorldClockCity(timezoneID: "Pacific/Auckland", city: "Auckland", country: "New Zealand"),
        WorldClockCity(timezoneID: "Pacific/Fiji", city: "Suva", country: "Fiji"),
    ]

    static func city(forID id: String) -> WorldClockCity? {
        allCities.first { $0.id == id }
    }
}

// MARK: - World Clock Inline Line
//
// REDESIGN.md R2: the world clock stopped being a band of pills — a
// permanent strip of chrome between the header and the timeline — and
// became one quiet machine-hint line inside the header block:
//
//   UTC 07:28 · Moscow 10:28 🌙 · Belgrade 09:28
//
// Same data, ~26 pt of vertical chrome returned to the canvas.
//
// The line is a horizontal carousel: when every clock doesn't fit the
// popover width it scrolls sideways with per-city snap instead of
// clipping mid-fact («Seoul 17…» is half a clock — PRINCIPLES §10,
// «strips that can overflow page with alignment snapping»). Edge fades
// appear only on the side that actually hides more content, so a
// fitting line looks exactly like the plain text it used to be.
struct WorldClockInlineLine: View {
    var settings: ReminderSettings
    @Environment(\.activeSkin) private var skin

    /// Scroll metrics feeding the edge fades: the content's frame in
    /// the carousel's coordinate space (`minX == -scrollOffset`) and
    /// the visible viewport width.
    @State private var contentFrame: CGRect = .zero
    @State private var viewportWidth: CGFloat = 0

    private static let coordinateSpace = "WorldClockCarousel"

    private var selectedCities: [WorldClockCity] {
        settings.worldClockCityIDs.compactMap { WorldClockCity.city(forID: $0) }
    }

    var body: some View {
        if settings.isWorldClockEnabled && !selectedCities.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                carousel(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func carousel(now: Date) -> some View {
        let segments = selectedCities.map { segment(for: $0, at: now) }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                // One Text per city (the « ·» separator rides the
                // preceding segment) so `viewAligned` snapping always
                // lands on a city's leading edge, never on a separator.
                ForEach(Array(segments.enumerated()), id: \.offset) { index, text in
                    // Secondary, not tertiary (DESIGN_REVIEW R7 tail):
                    // these are the times the user actually reads, and
                    // tertiary (~26% alpha) washed out over wallpapers —
                    // the worst-contrast line on the resting screen. The
                    // machineHint face still marks the voice as computed.
                    Text(index < segments.count - 1 ? "\(text) \u{00B7}" : text)
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .scrollTargetLayout()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: WorldClockContentFrameKey.self,
                        value: geo.frame(in: .named(Self.coordinateSpace))
                    )
                }
            )
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .scrollTargetBehavior(.viewAligned)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: WorldClockViewportWidthKey.self,
                    value: geo.size.width
                )
            }
        )
        .onPreferenceChange(WorldClockContentFrameKey.self) { contentFrame = $0 }
        .onPreferenceChange(WorldClockViewportWidthKey.self) { viewportWidth = $0 }
        .mask(edgeFadeMask)
        .help(verboseLine(for: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(verboseLine(for: now))
    }

    /// True while content extends beyond the corresponding edge — the
    /// only time the fade may dim anything (a fade over the last city
    /// when nothing follows would violate §10 in spirit).
    private var showsLeadingFade: Bool { contentFrame.minX < -1 }
    private var showsTrailingFade: Bool { contentFrame.maxX > viewportWidth + 1 }

    /// Mask with soft edges where (and only where) more clocks hide.
    private var edgeFadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: showsLeadingFade ? DS.Spacing.lg : 0)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: showsTrailingFade ? DS.Spacing.lg : 0)
        }
        .animation(DS.Animation.quick, value: showsLeadingFade)
        .animation(DS.Animation.quick, value: showsTrailingFade)
    }

    private func segment(for city: WorldClockCity, at now: Date) -> String {
        guard let tz = city.timeZone else { return city.city }
        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.timeStyle = .short
        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: now)
        let night = hour < 6 || hour >= 22 ? " \u{1F319}" : ""
        return "\(city.city) \(formatter.string(from: now))\(night)"
    }

    private func verboseLine(for now: Date) -> String {
        selectedCities.compactMap { city -> String? in
            guard let tz = city.timeZone else { return nil }
            let formatter = DateFormatter()
            formatter.timeZone = tz
            formatter.timeStyle = .short
            return "\(city.displayName): \(formatter.string(from: now))"
        }.joined(separator: ". ")
    }
}

// MARK: - Carousel scroll-metric keys

/// Content frame of the carousel's HStack in the carousel coordinate
/// space — `minX` is the negated scroll offset, `width` the full
/// content width.
private struct WorldClockContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Visible viewport width of the carousel's ScrollView.
private struct WorldClockViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
