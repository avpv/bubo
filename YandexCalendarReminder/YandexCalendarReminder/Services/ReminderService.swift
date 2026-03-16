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

    private var calDAVService: YandexCalDAVService?
    private var syncTimer: Timer?
    private var reminderTimers: [String: [Timer]] = [:]
    private var settings: ReminderSettings
    private var firedReminders: Set<String> = []

    var allEvents: [CalendarEvent] {
        (upcomingEvents + localEvents)
            .filter { $0.isUpcoming }
            .sorted { $0.startDate < $1.startDate }
    }

    init(settings: ReminderSettings) {
        self.settings = settings
        requestNotificationPermission()
        loadLocalEvents()
    }

    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
        setupCalDAVService()
        rescheduleAllReminders()
    }

    func setupCalDAVService() {
        guard !settings.yandexLogin.isEmpty, !settings.yandexAppPassword.isEmpty else {
            calDAVService = nil
            return
        }
        calDAVService = YandexCalDAVService(
            login: settings.yandexLogin,
            appPassword: settings.yandexAppPassword
        )
    }

    func startSync() {
        setupCalDAVService()
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
        guard let service = calDAVService else { return }
        isSyncing = true
        syncError = nil

        Task {
            do {
                let now = Date()
                let endDate = Calendar.current.date(byAdding: .day, value: 7, to: now)!
                let events = try await service.fetchEvents(from: now, to: endDate)

                await MainActor.run {
                    self.upcomingEvents = events
                    self.lastSyncDate = Date()
                    self.isSyncing = false
                    self.scheduleReminders(for: events)
                }
            } catch {
                await MainActor.run {
                    self.syncError = error.localizedDescription
                    self.isSyncing = false
                }
            }
        }
    }

    // MARK: - Local Events

    func addLocalEvent(_ event: CalendarEvent) {
        localEvents.append(event)
        saveLocalEvents()
        scheduleReminders(for: [event])
    }

    func removeLocalEvent(id: String) {
        localEvents.removeAll { $0.id == id }
        cancelReminders(for: id)
        saveLocalEvents()
    }

    private func saveLocalEvents() {
        if let data = try? JSONEncoder().encode(localEvents) {
            UserDefaults.standard.set(data, forKey: "LocalEvents")
        }
    }

    private func loadLocalEvents() {
        guard let data = UserDefaults.standard.data(forKey: "LocalEvents"),
              let events = try? JSONDecoder().decode([CalendarEvent].self, from: data) else { return }
        localEvents = events.filter { $0.isUpcoming }
    }

    // MARK: - Reminders

    private func scheduleReminders(for events: [CalendarEvent]) {
        let enabledIntervals = settings.intervals.filter { $0.isEnabled }

        for event in events where event.isUpcoming {
            cancelReminders(for: event.id)
            var timers: [Timer] = []

            for interval in enabledIntervals {
                let reminderKey = "\(event.id)_\(interval.minutes)"
                guard !firedReminders.contains(reminderKey) else { continue }

                let fireDate = event.startDate.addingTimeInterval(-TimeInterval(interval.minutes * 60))
                guard fireDate > Date() else { continue }

                let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.fireReminder(for: event, minutesBefore: interval.minutes)
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

    private func fireReminder(for event: CalendarEvent, minutesBefore: Int) {
        if settings.showSystemNotification {
            sendNotification(for: event, minutesBefore: minutesBefore)
        }

        if settings.showFullScreenAlert {
            showFullScreenAlert(for: event, minutesBefore: minutesBefore)
        }

        if settings.playSound {
            NSSound.beep()
        }
    }

    private func sendNotification(for event: CalendarEvent, minutesBefore: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Встреча через \(minutesBefore) мин"
        content.body = "\(event.title)\n\(event.formattedTime)"
        if let location = event.location {
            content.body += "\n\(location)"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(event.id)_\(minutesBefore)",
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}

extension Notification.Name {
    static let showFullScreenAlert = Notification.Name("showFullScreenAlert")
}
