import Foundation
import UserNotifications
import AppKit
import SwiftData

@MainActor
@Observable
class ReminderService {
    /// How many days ahead to fetch events. Used as the ceiling for badge time window.
    static let fetchWindowDays = 7

    var upcomingEvents: [CalendarEvent] = []
    var localEvents: [CalendarEvent] = []
    var lastSyncDate: Date?
    var syncError: String?
    var isSyncing = false
    var isUsingCache = false

    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var reminderTimers: [String: [Timer]] = [:]
    private var settings: ReminderSettings
    private var firedReminders: Set<String> = []
    private let eventCache: EventCache
    private let modelContainer: ModelContainer
    private nonisolated(unsafe) var settingsObserver: Any?
    private var excludedOccurrences: Set<String> = []
    private var localRemindersOverrides: [String: [Int]] = [:]
    private nonisolated(unsafe) var snoozeObserver: Any?
    private nonisolated(unsafe) var appleCalendarObserver: Any?
    private nonisolated(unsafe) var pendingAppleRefreshTask: Task<Void, Never>?
    private var hasCompletedLiveSync = false

    /// IDs of events currently playing their disintegration animation.
    /// These events are kept in the list briefly after ending so the dust effect can finish.
    private(set) var disintegratingEventIDs: Set<String> = []

    var allEvents: [CalendarEvent] {
        let expandedLocal = localEvents.flatMap {
            RecurrenceExpander.expand($0, excludedIds: excludedOccurrences)
        }
        return (upcomingEvents + expandedLocal)
            .filter { $0.isUpcoming || disintegratingEventIDs.contains($0.id) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Mark an event as disintegrating (keeps it visible while animation plays).
    func beginDisintegration(for eventID: String) {
        disintegratingEventIDs.insert(eventID)
    }

    /// Remove an event after its disintegration animation completes.
    func completeDisintegration(for eventID: String) {
        disintegratingEventIDs.remove(eventID)
    }

    /// Count of real (non-disintegrating) upcoming events — used to decide
    /// when to show the empty state so it appears before the dust settles.
    var nonDisintegratingEventCount: Int {
        allEvents.filter { !disintegratingEventIDs.contains($0.id) }.count
    }

    /// Number of remaining events to show as badge on the menu bar icon.
    var badgeCount: Int {
        guard settings.showBadgeCount else { return 0 }
        let calendar = Calendar.current
        let now = Date()

        let cutoff: Date
        switch settings.badgeCountMode {
        case .wholeDay:
            cutoff = calendar.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        case .timeWindow:
            cutoff = now.addingTimeInterval(TimeInterval(settings.badgeTimeWindowHours) * 60 * 60)
        }

        return allEvents.filter { event in
            event.startDate >= now && event.startDate < cutoff
        }.count
    }

    /// Events grouped by day for display, including days with no events
    var eventsByDay: [(date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        let today = calendar.startOfDay(for: Date())
        var results: [(date: Date, events: [CalendarEvent])] = []
        for offset in 0..<Self.fetchWindowDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let events = grouped[day] ?? []
            results.append((date: day, events: events))
        }
        return results
    }

    init(settings: ReminderSettings, modelContainer: ModelContainer) {
        self.settings = settings
        self.modelContainer = modelContainer
        self.eventCache = EventCache(modelContainer: modelContainer)
        requestNotificationPermission()
        loadLocalEvents()
        loadLocalRemindersOverrides()

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

        // Observe settings changes via NotificationCenter (replaces Combine pipeline)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: ReminderSettings.settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onSettingsChanged()
            }
        }

        // Auto-sync when Calendar.app data changes (edits, iCloud sync).
        // Debounced: EKEventStoreChanged can fire in bursts.
        appleCalendarObserver = NotificationCenter.default.addObserver(
            forName: AppleCalendarService.calendarDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleAppleCalendarRefresh()
            }
        }
    }

    private func onSettingsChanged() {
        // Immediately sync (which will drop external events if disabled)
        syncNow()
        startSyncTimer()
    }

    deinit {
        if let observer = snoozeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appleCalendarObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingAppleRefreshTask?.cancel()
        for timers in reminderTimers.values {
            timers.forEach { $0.invalidate() }
        }
        syncTimer?.invalidate()
    }

    private func scheduleAppleCalendarRefresh() {
        pendingAppleRefreshTask?.cancel()
        pendingAppleRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
        rescheduleAllReminders()
    }

    // MARK: - Sync

    func startSync() {
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
        guard settings.isCalendarSyncEnabled else {
            upcomingEvents = []
            isUsingCache = false
            syncError = "Calendar sync disabled"
            rescheduleAllReminders()
            return
        }

        guard AppleCalendarService.hasAccess else {
            syncError = "Calendar access not granted"
            return
        }

        isSyncing = true
        syncError = nil

        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: Self.fetchWindowDays, to: now) ?? now

        var events = AppleCalendarService.shared.fetchEvents(
            from: now,
            to: endDate,
            onlyCalendarIds: settings.selectedCalendarIds
        )

        // Apply local overrides
        for i in events.indices {
            let uniqueId = events[i].id
            let seriesOverrides = events[i].seriesId.flatMap { localRemindersOverrides[$0] }
            let exactOverrides = localRemindersOverrides[uniqueId]
            
            if let active = exactOverrides ?? seriesOverrides {
                events[i].customReminderMinutes = active.isEmpty ? nil : active
            }
        }

        upcomingEvents = events.sorted { $0.startDate < $1.startDate }
        lastSyncDate = Date()
        isSyncing = false
        isUsingCache = false
        hasCompletedLiveSync = true

        // Clean up firedReminders for events no longer in the window
        let currentEventIds = Set(events.map { $0.id })
        firedReminders = firedReminders.filter { key in
            guard let lastUnderscore = key.lastIndex(of: "_") else { return false }
            let eventId = String(key[..<lastUnderscore])
            return currentEventIds.contains(eventId)
        }

        scheduleReminders(for: events)

        // Ask EventKit to pull fresh data from remote calendar servers
        // (iCloud, Google, Exchange, CalDAV). If there are changes (e.g. a
        // deletion made on the remote side), EventKit will fire
        // EKEventStoreChanged and we'll sync again automatically.
        AppleCalendarService.shared.triggerRemoteRefresh()

        Task {
            await eventCache.save(events: events)
        }
    }

    // MARK: - Cache

    private func loadCachedEvents() {
        Task {
            let cached = await eventCache.loadEvents()
            // Only use cache if a live sync hasn't already completed —
            // prevents stale cached data from overwriting fresh results.
            if !cached.isEmpty && !self.hasCompletedLiveSync && self.upcomingEvents.isEmpty {
                self.upcomingEvents = cached
                self.isUsingCache = true
                self.scheduleReminders(for: cached)
            }
        }
    }

    // MARK: - Local Events

    func addCalendarEvent(_ event: CalendarEvent, calendarId: String? = nil) {
        do {
            // For pomodoro events, expand into work + break + long break events
            if event.eventType == .pomodoro, event.recurrenceRule?.isPomodoro == true {
                let expanded = RecurrenceExpander.expand(event)
                for occurrence in expanded {
                    // Create each expanded event without recurrence rule (they are individual events)
                    let calEvent = CalendarEvent(
                        id: occurrence.id,
                        title: occurrence.title,
                        startDate: occurrence.startDate,
                        endDate: occurrence.endDate,
                        location: occurrence.location,
                        description: occurrence.description,
                        calendarName: occurrence.calendarName,
                        eventType: occurrence.eventType
                    )
                    try AppleCalendarService.shared.createEvent(calEvent, calendarId: calendarId)
                }
            } else {
                try AppleCalendarService.shared.createEvent(event, calendarId: calendarId)
            }
            syncNow()
        } catch {
            print("Failed to create Apple Calendar event: \(error)")
        }
    }

    func addLocalEvent(_ event: CalendarEvent) {
        localEvents.append(event)
        saveLocalEvents()
        scheduleReminders(for: RecurrenceExpander.expand(event, excludedIds: excludedOccurrences))
    }

    func removeLocalEvent(id: String) {
        if let event = localEvents.first(where: { $0.id == id }) {
            let expanded = RecurrenceExpander.expand(event, excludedIds: excludedOccurrences)
            for occurrence in expanded { cancelReminders(for: occurrence.id) }
        }
        excludedOccurrences = excludedOccurrences.filter { !$0.hasPrefix(id) }
        saveExcludedOccurrences()
        localEvents.removeAll { $0.id == id }
        saveLocalEvents()
    }

    func excludeOccurrence(occurrenceId: String) {
        excludedOccurrences.insert(occurrenceId)
        saveExcludedOccurrences()
        cancelReminders(for: occurrenceId)
    }

    func seriesEvent(for event: CalendarEvent) -> CalendarEvent? {
        guard let sid = event.seriesId else { return nil }
        return localEvents.first { $0.id == sid }
    }

    func updateLocalEvent(_ event: CalendarEvent) {
        guard let index = localEvents.firstIndex(where: { $0.id == event.id }) else { return }
        let oldExpanded = RecurrenceExpander.expand(localEvents[index], excludedIds: excludedOccurrences)
        for occurrence in oldExpanded { cancelReminders(for: occurrence.id) }
        localEvents[index] = event
        saveLocalEvents()
        scheduleReminders(for: RecurrenceExpander.expand(event, excludedIds: excludedOccurrences))
    }

    private func saveLocalEvents() {
        let context = ModelContext(modelContainer)
        do {
            // Fetch existing persisted events to diff against
            let existing = try context.fetch(FetchDescriptor<PersistedLocalEvent>())
            let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.eventId, $0) })
            let currentIds = Set(localEvents.map { $0.id })

            // Delete removed events
            for persisted in existing where !currentIds.contains(persisted.eventId) {
                context.delete(persisted)
            }

            // Insert or update
            for event in localEvents {
                if let persisted = existingById[event.id] {
                    persisted.update(from: event)
                } else {
                    context.insert(PersistedLocalEvent(from: event))
                }
            }

            try context.save()
        } catch {
            print("ReminderService: failed to save local events: \(error)")
        }
    }

    private func loadLocalEvents() {
        let context = ModelContext(modelContainer)
        do {
            let persisted = try context.fetch(FetchDescriptor<PersistedLocalEvent>())
            localEvents = persisted
                .map { $0.toCalendarEvent() }
                .filter { $0.isUpcoming || $0.recurrenceRule != nil }
            loadExcludedOccurrences()
        } catch {
            print("ReminderService: failed to load local events: \(error)")
        }
    }

    private func saveExcludedOccurrences() {
        let context = ModelContext(modelContainer)
        do {
            try context.delete(model: PersistedExcludedOccurrence.self)
            for id in excludedOccurrences {
                context.insert(PersistedExcludedOccurrence(occurrenceId: id))
            }
            try context.save()
        } catch {
            print("ReminderService: failed to save excluded occurrences: \(error)")
        }
    }

    private func loadExcludedOccurrences() {
        let context = ModelContext(modelContainer)
        do {
            let persisted = try context.fetch(FetchDescriptor<PersistedExcludedOccurrence>())
            excludedOccurrences = Set(persisted.map { $0.occurrenceId })
        } catch {
            print("ReminderService: failed to load excluded occurrences: \(error)")
        }
    }

    // MARK: - Local Reminder Overrides

    func updateLocalReminder(for eventId: String, minutes: [Int]?) {
        localRemindersOverrides[eventId] = minutes ?? []
        saveLocalRemindersOverrides()

        // Apply immediately to the current state if it's an upcoming event
        if let idx = upcomingEvents.firstIndex(where: { $0.id == eventId }) {
            upcomingEvents[idx].customReminderMinutes = minutes
            scheduleReminders(for: [upcomingEvents[idx]])
        } else if let idx = localEvents.firstIndex(where: { $0.id == eventId }) {
            localEvents[idx].customReminderMinutes = minutes
            scheduleReminders(for: RecurrenceExpander.expand(localEvents[idx], excludedIds: excludedOccurrences))
        }
    }

    private func saveLocalRemindersOverrides() {
        let context = ModelContext(modelContainer)
        do {
            try context.delete(model: PersistedReminderOverride.self)
            for (eventId, minutes) in localRemindersOverrides {
                context.insert(PersistedReminderOverride(eventId: eventId, minutes: minutes))
            }
            try context.save()
        } catch {
            print("ReminderService: failed to save reminder overrides: \(error)")
        }
    }

    private func loadLocalRemindersOverrides() {
        let context = ModelContext(modelContainer)
        do {
            let persisted = try context.fetch(FetchDescriptor<PersistedReminderOverride>())
            localRemindersOverrides = Dictionary(
                uniqueKeysWithValues: persisted.map { ($0.eventId, $0.minutes) }
            )
        } catch {
            print("ReminderService: failed to load reminder overrides: \(error)")
        }
    }

    // MARK: - Snooze

    func snoozeReminder(for event: CalendarEvent, minutes: Int) {
        if event.isLocalEvent {
            let interval = TimeInterval(minutes * 60)
            let updatedEvent = CalendarEvent(
                id: event.id,
                title: event.title,
                startDate: event.startDate.addingTimeInterval(interval),
                endDate: event.endDate.addingTimeInterval(interval),
                location: event.location,
                description: event.description,
                calendarName: event.calendarName,
                customReminderMinutes: event.customReminderMinutes,
                recurrenceRule: event.recurrenceRule,
                seriesId: event.seriesId,
                eventType: event.eventType
            )
            updateLocalEvent(updatedEvent)
        } else {
            do {
                try AppleCalendarService.shared.shiftEventTime(id: event.id, byMinutes: minutes)
            } catch {
                print("Failed to shift Apple Calendar event time: \(error)")
            }
        }
    }

    // MARK: - Reminders

    private static let defaultReminderMinutes = [5]

    /// The default reminder minutes that would apply to an event without custom reminders.
    var defaultReminderMinutesList: [Int] {
        let enabledIntervals = settings.intervals.filter { $0.isEnabled }
        if !enabledIntervals.isEmpty {
            return enabledIntervals.map { $0.minutes }.sorted()
        }
        return Self.defaultReminderMinutes
    }

    func activeReminderMinutes(for event: CalendarEvent) -> [Int] {
        if let custom = event.customReminderMinutes {
            return custom
        }
        let enabledIntervals = settings.intervals.filter { $0.isEnabled }
        if !enabledIntervals.isEmpty {
            return enabledIntervals.map { $0.minutes }
        }
        return Self.defaultReminderMinutes
    }

    private func scheduleReminders(for events: [CalendarEvent]) {
        for event in events where event.isUpcoming {
            cancelReminders(for: event.id)
            var timers: [Timer] = []

            let minutesList = activeReminderMinutes(for: event)

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
