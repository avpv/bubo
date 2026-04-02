import Foundation
import SwiftData

/// Offline cache for calendar events, backed by SwiftData.
actor EventCache {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    @discardableResult
    func save(events: [CalendarEvent]) -> Bool {
        let context = ModelContext(modelContainer)
        // Delete all existing cached events
        do {
            try context.delete(model: PersistedCachedEvent.self)
        } catch {
            print("EventCache: failed to clear old cache: \(error)")
            return false
        }

        let now = Date()
        for event in events {
            context.insert(PersistedCachedEvent(from: event, cachedAt: now))
        }

        do {
            try context.save()
            return true
        } catch {
            print("EventCache: failed to save cache: \(error)")
            return false
        }
    }

    func loadEvents() -> [CalendarEvent] {
        let context = ModelContext(modelContainer)
        let now = Date()
        let descriptor = FetchDescriptor<PersistedCachedEvent>(
            predicate: #Predicate { $0.startDate > now }
        )
        do {
            return try context.fetch(descriptor).map { $0.toCalendarEvent() }
        } catch {
            print("EventCache: failed to load: \(error)")
            return []
        }
    }

    func cacheAge() -> TimeInterval? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<PersistedCachedEvent>(
            sortBy: [SortDescriptor(\.cachedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let newest = try? context.fetch(descriptor).first else { return nil }
        return Date().timeIntervalSince(newest.cachedAt)
    }

    func clear() {
        let context = ModelContext(modelContainer)
        do {
            try context.delete(model: PersistedCachedEvent.self)
            try context.save()
        } catch {
            print("EventCache: failed to clear: \(error)")
        }
    }
}
