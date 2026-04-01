import SwiftUI

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

// MARK: - World Clock Strip

struct WorldClockStripView: View {
    var settings: ReminderSettings
    @Environment(\.activeSkin) private var skin

    private var selectedCities: [WorldClockCity] {
        settings.worldClockCityIDs.compactMap { WorldClockCity.city(forID: $0) }
    }

    var body: some View {
        if settings.isWorldClockEnabled && !selectedCities.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(selectedCities) { city in
                            WorldClockPill(city: city, now: context.date)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.xs)
                }
            }
        }
    }
}

// MARK: - World Clock Pill

private struct WorldClockPill: View {
    let city: WorldClockCity
    let now: Date
    @Environment(\.activeSkin) private var skin

    private var chipAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    private var timeString: String {
        guard let tz = city.timeZone else { return "--:--" }
        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.timeStyle = .short
        return formatter.string(from: now)
    }

    private var offsetLabel: String {
        guard let tz = city.timeZone else { return "" }
        let localOffset = TimeZone.current.secondsFromGMT(for: now)
        let cityOffset = tz.secondsFromGMT(for: now)
        let diffHours = Double(cityOffset - localOffset) / 3600.0
        if diffHours == 0 { return "" }
        let sign = diffHours > 0 ? "+" : ""
        if diffHours == diffHours.rounded() {
            return "\(sign)\(Int(diffHours))h"
        }
        return "\(sign)\(String(format: "%.1f", diffHours))h"
    }

    private var isNighttime: Bool {
        guard let tz = city.timeZone else { return false }
        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: now)
        return hour < 6 || hour >= 22
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(city.city)
                .font(.system(.caption2, design: skin.resolvedFontDesign, weight: skin.resolvedFontWeight))
                .foregroundStyle(skin.resolvedTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if isNighttime {
                Image(systemName: "moon.fill")
                    .font(.system(size: DS.Size.worldClockMoonSize, weight: skin.resolvedSymbolWeight))
                    .foregroundStyle(skin.resolvedTextTertiary)
            }

            Text(timeString)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(skin.resolvedTextPrimary)

            if !offsetLabel.isEmpty {
                Text(offsetLabel)
                    .font(.system(.caption2, design: .monospaced, weight: skin.resolvedFontWeight))
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background {
            if isNighttime {
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                    .fill(chipAccent.opacity(DS.Opacity.lightFill))
            }
        }
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }
}
