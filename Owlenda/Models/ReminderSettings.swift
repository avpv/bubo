import Foundation

struct ReminderInterval: Identifiable, Codable, Hashable {
    let id: UUID
    var minutes: Int
    var isEnabled: Bool

    init(minutes: Int, isEnabled: Bool = true) {
        self.id = UUID()
        self.minutes = minutes
        self.isEnabled = isEnabled
    }

    var displayText: String {
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes == 0 {
                return "\(hours) h"
            }
            return "\(hours) h \(remainingMinutes) min"
        }
        return "\(minutes) min"
    }
}

@Observable
class ReminderSettings: Codable {
    static let settingsDidChange = Notification.Name("ReminderSettingsDidChange")

    var intervals: [ReminderInterval] { didSet { scheduleSave() } }
    var syncIntervalMinutes: Int { didSet { scheduleSave() } }
    var showFullScreenAlert: Bool { didSet { scheduleSave() } }
    var showSystemNotification: Bool { didSet { scheduleSave() } }
    var launchAtLogin: Bool
    var doNotDisturbEnabled: Bool { didSet { scheduleSave() } }
    var doNotDisturbFrom: Date { didSet { scheduleSave() } }
    var doNotDisturbTo: Date { didSet { scheduleSave() } }
    var selectedCalendarIds: [String] { didSet { scheduleSave() } }

    // Task-based debounced save — replaces Combine pipeline
    private var saveTask: Task<Void, Never>?

    enum CodingKeys: String, CodingKey {
        case intervals, syncIntervalMinutes, showFullScreenAlert, showSystemNotification
        case doNotDisturbEnabled, doNotDisturbFrom, doNotDisturbTo
        case selectedCalendarIds
    }

    init() {
        self.intervals = [
            ReminderInterval(minutes: 20),
            ReminderInterval(minutes: 2)
        ]
        self.syncIntervalMinutes = 5
        self.showFullScreenAlert = true
        self.showSystemNotification = true
        self.launchAtLogin = false
        self.doNotDisturbEnabled = false
        // Default DND: 22:00 - 08:00
        let calendar = Calendar.current
        self.doNotDisturbFrom = calendar.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
        self.doNotDisturbTo = calendar.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
        self.selectedCalendarIds = [] // empty = sync all
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intervals = try container.decode([ReminderInterval].self, forKey: .intervals)
        syncIntervalMinutes = try container.decode(Int.self, forKey: .syncIntervalMinutes)
        showFullScreenAlert = try container.decode(Bool.self, forKey: .showFullScreenAlert)
        showSystemNotification = try container.decodeIfPresent(Bool.self, forKey: .showSystemNotification) ?? true
        launchAtLogin = false
        doNotDisturbEnabled = try container.decodeIfPresent(Bool.self, forKey: .doNotDisturbEnabled) ?? false

        let calendar = Calendar.current
        doNotDisturbFrom = try container.decodeIfPresent(Date.self, forKey: .doNotDisturbFrom)
            ?? calendar.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
        doNotDisturbTo = try container.decodeIfPresent(Date.self, forKey: .doNotDisturbTo)
            ?? calendar.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
        selectedCalendarIds = try container.decodeIfPresent([String].self, forKey: .selectedCalendarIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(syncIntervalMinutes, forKey: .syncIntervalMinutes)
        try container.encode(showFullScreenAlert, forKey: .showFullScreenAlert)
        try container.encode(showSystemNotification, forKey: .showSystemNotification)
        try container.encode(doNotDisturbEnabled, forKey: .doNotDisturbEnabled)
        try container.encode(doNotDisturbFrom, forKey: .doNotDisturbFrom)
        try container.encode(doNotDisturbTo, forKey: .doNotDisturbTo)
        try container.encode(selectedCalendarIds, forKey: .selectedCalendarIds)
    }

    /// Check if current time is within Do Not Disturb period
    var isDoNotDisturbActive: Bool {
        guard doNotDisturbEnabled else { return false }

        let calendar = Calendar.current
        let now = Date()
        let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let fromMinutes = calendar.component(.hour, from: doNotDisturbFrom) * 60 + calendar.component(.minute, from: doNotDisturbFrom)
        let toMinutes = calendar.component(.hour, from: doNotDisturbTo) * 60 + calendar.component(.minute, from: doNotDisturbTo)

        if fromMinutes == toMinutes {
            return false
        } else if fromMinutes < toMinutes {
            return currentMinutes >= fromMinutes && currentMinutes < toMinutes
        } else {
            return currentMinutes >= fromMinutes || currentMinutes < toMinutes
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
            NotificationCenter.default.post(name: Self.settingsDidChange, object: nil)
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "ReminderSettings")
        }
    }

    static func load() -> ReminderSettings {
        guard let data = UserDefaults.standard.data(forKey: "ReminderSettings"),
              let settings = try? JSONDecoder().decode(ReminderSettings.self, from: data) else {
            return ReminderSettings()
        }
        return settings
    }
}
