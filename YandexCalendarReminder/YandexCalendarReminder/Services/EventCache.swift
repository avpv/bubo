import Foundation

/// Offline cache for calendar events
actor EventCache {
    private let cacheKey = "CachedCalendarEvents"
    private let cacheTimestampKey = "CachedEventsTimestamp"

    struct CachedData: Codable {
        let events: [CalendarEvent]
        let timestamp: Date
    }

    func save(events: [CalendarEvent]) {
        let cached = CachedData(events: events, timestamp: Date())
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    func load() -> CachedData? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedData.self, from: data) else {
            return nil
        }
        return cached
    }

    func loadEvents() -> [CalendarEvent] {
        guard let cached = load() else { return [] }
        // Return only future events
        return cached.events.filter { $0.startDate > Date() }
    }

    func cacheAge() -> TimeInterval? {
        guard let cached = load() else { return nil }
        return Date().timeIntervalSince(cached.timestamp)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }
}
