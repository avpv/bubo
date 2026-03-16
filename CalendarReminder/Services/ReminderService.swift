import Foundation
import UserNotifications
import AppKit

@MainActor
class ReminderService: ObservableObject {
    @Published var upcomingEvents: [CalendarEvent] = []
    @Published var localEvents: [CalendarEvent] = []
    @Published var lastSyncDate: Date?
    @Published var syncError: String?
    @Published var isSyncing = false
    @Published var isUsingCache = false

    private var calDAVService: YandexCalDAVService?
    private var googleService: GoogleCalendarService?
    private var syncTimer: Timer?
    private var reminderTimers: [String: [Timer]] = [:]
    private var settings: ReminderSettings
    private var firedReminders: Set<String> = []
    private let eventCache = EventCache()
    private var networkMonitor: NetworkMonitor?

    var allEvents: [CalendarEvent] {
        let expandedLocal = localEvents.flatMap { Self.expandRecurringEvent($0) }
        return (upcomingEvents + expandedLocal)
            .filter { $0.isUpcoming }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Expands a recurring local event into individual occurrences within a 7-day window.
    static func expandRecurringEvent(_ event: CalendarEvent) -> [CalendarEvent] {
        guard let rule = event.recurrenceRule else { return [event] }

        let calendar = Calendar.current
        let eventDuration = event.endDate.timeIntervalSince(event.startDate)
        let windowEnd = calendar.date(byAdding: .day, value: 7, to: Date()) ?? Date()

        var occurrences: [CalendarEvent] = []
        var current = event.startDate
        var count = 0
        let maxCount: Int? = {
            if case .afterCount(let n) = rule.end { return n }
            return nil
        }()
        let untilDate: Date? = {
            if case .untilDate(let d) = rule.end { return d }
            return nil
        }()

        while current <= windowEnd {
            // Check end conditions
            if let until = untilDate, current > until { break }
            if let max = maxCount, count >= max { break }

            // For weekly with specific weekdays, check if current day matches
            let shouldInclude: Bool
            if rule.frequency == .weekly && !rule.weekdays.isEmpty {
                let weekday = calendar.component(.weekday, from: current)
                shouldInclude = rule.weekdays.contains { $0.calendarWeekday == weekday }
            } else {
                shouldInclude = true
            }

            if shouldInclude && current >= event.startDate {
                let end = current.addingTimeInterval(eventDuration)
                let occurrence = CalendarEvent(
                    id: count == 0 ? event.id : "\(event.id)_r\(Int(current.timeIntervalSince1970))",
                    title: event.title,
                    startDate: current,
                    endDate: end,
                    location: event.location,
                    description: event.description,
                    calendarName: event.calendarName,
                    customReminderMinutes: event.customReminderMinutes,
                    recurrenceRule: count == 0 ? event.recurrenceRule : nil,
                    seriesId: event.id
                )
                occurrences.append(occurrence)
                count += 1
            }

            // Advance to next candidate date
            current = Self.nextOccurrence(after: current, rule: rule, calendar: calendar)
        }

        return occurrences.isEmpty ? [event] : occurrences
    }

    private static func nextOccurrence(after date: Date, rule: RecurrenceRule, calendar: Calendar) -> Date {
        switch rule.frequency {
        case .minutely:
            return date.addingTimeInterval(TimeInterval(rule.interval * 60))
        case .daily:
            return calendar.date(byAdding: .day, value: rule.interval, to: date) ?? date
        case .weekly:
            if rule.weekdays.isEmpty {
                return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date) ?? date
            }
            // For weekly with specific weekdays, advance one day at a time
            // and check if we crossed a week boundary for interval > 1
            var next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            let startWeek = calendar.component(.weekOfYear, from: date)
            let nextWeek = calendar.component(.weekOfYear, from: next)
            if nextWeek != startWeek && rule.interval > 1 {
                // Jumped to new week — skip (interval - 1) weeks
                next = calendar.date(byAdding: .weekOfYear, value: rule.interval - 1, to: next) ?? next
            }
            return next
        case .monthly:
            return calendar.date(byAdding: .month, value: rule.interval, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: rule.interval, to: date) ?? date
        }
    }

    /// Events grouped by day for display
    var eventsByDay: [(date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, events: $0.value) }
    }

    private var snoozeObserver: Any?

    init(settings: ReminderSettings) {
        self.settings = settings
        requestNotificationPermission()
        loadLocalEvents()

        // Listen for snooze from full-screen alert
        snoozeObserver = NotificationCenter.default.addObserver(
            forName: .snoozeReminder,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let event = notification.userInfo?["event"] as? CalendarEvent,
                  let minutes = notification.userInfo?["minutes"] as? Int else { return }
            Task { @MainActor in
                self.snoozeReminder(for: event, minutes: minutes)
            }
        }
    }

    deinit {
        if let observer = snoozeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for timers in reminderTimers.values {
            timers.forEach { $0.invalidate() }
        }
        syncTimer?.invalidate()
    }

    func setNetworkMonitor(_ monitor: NetworkMonitor) {
        self.networkMonitor = monitor
    }

    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
        setupCalDAVService()
        rescheduleAllReminders()
    }

    func setupCalDAVService() {
        // Yandex
        let login = settings.yandexLogin
        let password = settings.yandexAppPassword

        switch settings.authMethod {
        case .appPassword:
            guard !login.isEmpty, !password.isEmpty else {
                calDAVService = nil
                break
            }
            calDAVService = YandexCalDAVService(authMode: .appPassword(login: login, password: password))
        case .oauth:
            guard YandexOAuthService.isAuthenticated else {
                calDAVService = nil
                break
            }
            calDAVService = YandexCalDAVService(authMode: .oauth)
        }

        // Google
        if settings.googleEnabled && GoogleOAuthService.isAuthenticated {
            googleService = GoogleCalendarService()
        } else {
            googleService = nil
        }
    }

    func startSync() {
        setupCalDAVService()
        loadCachedEvents()
        syncNow()
        startSyncTimer()
    }

    func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        for timers in reminderTimers.values {
            timers.forEach { $0.invalidate() }
        }
        reminderTimers.removeAll()
    }

    func startSyncTimer() {
        syncTimer?.invalidate()
        let interval = TimeInterval(settings.syncIntervalMinutes * 60)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
    }

    func syncNow() {
        // Check network
        if let monitor = networkMonitor, !monitor.isConnected {
            syncError = "No internet connection"
            loadCachedEvents()
            return
        }

        let hasAnyProvider = calDAVService != nil || googleService != nil
        guard hasAnyProvider else { return }

        isSyncing = true
        syncError = nil

        Task {
            let now = Date()
            let endDate = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
            var allEvents: [CalendarEvent] = []
            var errors: [String] = []

            // Yandex
            if let yandexService = calDAVService {
                do {
                    let events = try await yandexService.fetchEvents(
                        from: now,
                        to: endDate,
                        onlyCalendars: self.settings.selectedCalendarHrefs
                    )
                    allEvents.append(contentsOf: events)
                } catch {
                    errors.append("Yandex: \(error.localizedDescription)")
                }
            }

            // Google
            if let googleSvc = googleService {
                do {
                    let events = try await RetryHelper.withRetry {
                        try await googleSvc.fetchEvents(
                            from: now,
                            to: endDate,
                            onlyCalendarIds: self.settings.selectedGoogleCalendarIds
                        )
                    }
                    allEvents.append(contentsOf: events)
                } catch {
                    errors.append("Google: \(error.localizedDescription)")
                }
            }

            allEvents.sort { $0.startDate < $1.startDate }

            self.upcomingEvents = allEvents
            self.lastSyncDate = Date()
            self.isSyncing = false
            self.syncError = errors.isEmpty ? nil : errors.joined(separator: "\n")
            self.isUsingCache = false

            // Clean up firedReminders for events no longer in the window
            let currentEventIds = Set(allEvents.map { $0.id })
            self.firedReminders = self.firedReminders.filter { key in
                // reminderKey format: "\(event.id)_\(interval.minutes)"
                // Find the last underscore to split id from minutes suffix
                guard let lastUnderscore = key.lastIndex(of: "_") else { return false }
                let eventId = String(key[..<lastUnderscore])
                return currentEventIds.contains(eventId)
            }

            self.scheduleReminders(for: allEvents)

            await eventCache.save(events: allEvents)

            // If all providers failed, fall back to cache
            if allEvents.isEmpty && !errors.isEmpty {
                self.loadCachedEvents()
            }
        }
    }

    // MARK: - Cache

    private func loadCachedEvents() {
        Task {
            let cached = await eventCache.loadEvents()
            if !cached.isEmpty && self.upcomingEvents.isEmpty {
                self.upcomingEvents = cached
                self.isUsingCache = true
                self.scheduleReminders(for: cached)
            }
        }
    }

    // MARK: - Local Events

    func addLocalEvent(_ event: CalendarEvent) {
        localEvents.append(event)
        saveLocalEvents()
        scheduleReminders(for: Self.expandRecurringEvent(event))
    }

    /// Remove the entire recurring series (by the base event id).
    func removeLocalEvent(id: String) {
        if let event = localEvents.first(where: { $0.id == id }) {
            let expanded = Self.expandRecurringEvent(event)
            for occurrence in expanded {
                cancelReminders(for: occurrence.id)
            }
        }
        localEvents.removeAll { $0.id == id }
        saveLocalEvents()
    }

    /// Find the base series event for an expanded occurrence.
    func seriesEvent(for event: CalendarEvent) -> CalendarEvent? {
        guard let sid = event.seriesId else { return nil }
        return localEvents.first { $0.id == sid }
    }

    func updateLocalEvent(_ event: CalendarEvent) {
        guard let index = localEvents.firstIndex(where: { $0.id == event.id }) else { return }
        // Cancel reminders for all occurrences of the old event
        let oldExpanded = Self.expandRecurringEvent(localEvents[index])
        for occurrence in oldExpanded {
            cancelReminders(for: occurrence.id)
        }
        localEvents[index] = event
        saveLocalEvents()
        scheduleReminders(for: Self.expandRecurringEvent(event))
    }

    private func saveLocalEvents() {
        if let data = try? JSONEncoder().encode(localEvents) {
            UserDefaults.standard.set(data, forKey: "LocalEvents")
        }
    }

    private func loadLocalEvents() {
        guard let data = UserDefaults.standard.data(forKey: "LocalEvents"),
              let events = try? JSONDecoder().decode([CalendarEvent].self, from: data) else { return }
        localEvents = events.filter { $0.isUpcoming || $0.recurrenceRule != nil }
    }

    // MARK: - Snooze

    func snoozeReminder(for event: CalendarEvent, minutes: Int) {
        let snoozeDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let timer = Timer(fire: snoozeDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireReminder(for: event, minutesBefore: 0, isSnooze: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        // Store timer
        var timers = reminderTimers[event.id] ?? []
        timers.append(timer)
        reminderTimers[event.id] = timers
    }

    // MARK: - Reminders

    private static let defaultReminderMinutes = [5]

    private func scheduleReminders(for events: [CalendarEvent]) {
        let enabledIntervals = settings.intervals.filter { $0.isEnabled }

        for event in events where event.isUpcoming {
            cancelReminders(for: event.id)
            var timers: [Timer] = []

            // Per-event custom reminders take priority, then global settings, then default 5 min
            let minutesList: [Int]
            if let custom = event.customReminderMinutes, !custom.isEmpty {
                minutesList = custom
            } else if !enabledIntervals.isEmpty {
                minutesList = enabledIntervals.map { $0.minutes }
            } else {
                minutesList = Self.defaultReminderMinutes
            }

            for minutes in minutesList {
                let reminderKey = "\(event.id)_\(minutes)"
                guard !firedReminders.contains(reminderKey) else { continue }

                let fireDate = event.startDate.addingTimeInterval(-TimeInterval(minutes * 60))
                guard fireDate > Date() else { continue }

                let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.fireReminder(for: event, minutesBefore: minutes, isSnooze: false)
                        self?.firedReminders.insert(reminderKey)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
            }

            if !timers.isEmpty {
                reminderTimers[event.id] = timers
            }
        }
    }

    private func cancelReminders(for eventId: String) {
        reminderTimers[eventId]?.forEach { $0.invalidate() }
        reminderTimers.removeValue(forKey: eventId)
    }

    private func rescheduleAllReminders() {
        for timers in reminderTimers.values {
            timers.forEach { $0.invalidate() }
        }
        reminderTimers.removeAll()
        firedReminders.removeAll()
        scheduleReminders(for: allEvents)
    }

    private func fireReminder(for event: CalendarEvent, minutesBefore: Int, isSnooze: Bool) {
        // Check Do Not Disturb (but always fire snooze — user explicitly asked)
        if !isSnooze && settings.isDoNotDisturbActive {
            return
        }

        if settings.showSystemNotification {
            sendNotification(for: event, minutesBefore: minutesBefore, isSnooze: isSnooze)
        }

        if settings.showFullScreenAlert {
            showFullScreenAlert(for: event, minutesBefore: minutesBefore)
        }

    }

    private func sendNotification(for event: CalendarEvent, minutesBefore: Int, isSnooze: Bool) {
        let content = UNMutableNotificationContent()

        if isSnooze {
            content.title = "Reminder (snoozed)"
        } else if minutesBefore <= 0 {
            content.title = "Meeting starting!"
        } else {
            content.title = "Meeting in \(minutesBefore) min"
        }

        content.body = "\(event.title)\n\(event.formattedTime)"
        if let location = event.location {
            content.body += "\n\(location)"
        }
        let request = UNNotificationRequest(
            identifier: "\(event.id)_\(minutesBefore)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func showFullScreenAlert(for event: CalendarEvent, minutesBefore: Int) {
        NotificationCenter.default.post(
            name: .showFullScreenAlert,
            object: nil,
            userInfo: [
                "event": event,
                "minutesBefore": minutesBefore
            ]
        )
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }
}

extension Notification.Name {
    static let showFullScreenAlert = Notification.Name("showFullScreenAlert")
}
