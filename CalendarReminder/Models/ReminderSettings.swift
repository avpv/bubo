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

enum AuthMethod: String, Codable {
    case appPassword
    case oauth
}

class ReminderSettings: ObservableObject, Codable {
    @Published var intervals: [ReminderInterval]
    @Published var syncIntervalMinutes: Int
    @Published var showFullScreenAlert: Bool
    @Published var showSystemNotification: Bool
    @Published var playSound: Bool
    @Published var launchAtLogin: Bool
    @Published var authMethod: AuthMethod
    @Published var doNotDisturbEnabled: Bool
    @Published var doNotDisturbFrom: Date  // time only
    @Published var doNotDisturbTo: Date    // time only
    @Published var selectedCalendarHrefs: [String]  // empty = all Yandex calendars
    @Published var googleEnabled: Bool
    @Published var selectedGoogleCalendarIds: [String]  // empty = all Google calendars

    enum CodingKeys: String, CodingKey {
        case intervals, syncIntervalMinutes, showFullScreenAlert, showSystemNotification
        case playSound, launchAtLogin, authMethod
        case doNotDisturbEnabled, doNotDisturbFrom, doNotDisturbTo
        case selectedCalendarHrefs
        case googleEnabled, selectedGoogleCalendarIds
    }

    init() {
        self.intervals = [
            ReminderInterval(minutes: 20),
            ReminderInterval(minutes: 2)
        ]
        self.syncIntervalMinutes = 5
        self.showFullScreenAlert = true
        self.showSystemNotification = true
        self.playSound = true
        self.launchAtLogin = false
        self.authMethod = .appPassword
        self.doNotDisturbEnabled = false
        // Default DND: 22:00 - 08:00
        let calendar = Calendar.current
        self.doNotDisturbFrom = calendar.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
        self.doNotDisturbTo = calendar.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
        self.selectedCalendarHrefs = [] // empty = sync all
        self.googleEnabled = false
        self.selectedGoogleCalendarIds = []
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intervals = try container.decode([ReminderInterval].self, forKey: .intervals)
        syncIntervalMinutes = try container.decode(Int.self, forKey: .syncIntervalMinutes)
        showFullScreenAlert = try container.decode(Bool.self, forKey: .showFullScreenAlert)
        showSystemNotification = try container.decodeIfPresent(Bool.self, forKey: .showSystemNotification) ?? true
        playSound = try container.decode(Bool.self, forKey: .playSound)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .appPassword
        doNotDisturbEnabled = try container.decodeIfPresent(Bool.self, forKey: .doNotDisturbEnabled) ?? false

        let calendar = Calendar.current
        doNotDisturbFrom = try container.decodeIfPresent(Date.self, forKey: .doNotDisturbFrom)
            ?? calendar.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
        doNotDisturbTo = try container.decodeIfPresent(Date.self, forKey: .doNotDisturbTo)
            ?? calendar.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
        selectedCalendarHrefs = try container.decodeIfPresent([String].self, forKey: .selectedCalendarHrefs) ?? []
        googleEnabled = try container.decodeIfPresent(Bool.self, forKey: .googleEnabled) ?? false
        selectedGoogleCalendarIds = try container.decodeIfPresent([String].self, forKey: .selectedGoogleCalendarIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(syncIntervalMinutes, forKey: .syncIntervalMinutes)
        try container.encode(showFullScreenAlert, forKey: .showFullScreenAlert)
        try container.encode(showSystemNotification, forKey: .showSystemNotification)
        try container.encode(playSound, forKey: .playSound)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(doNotDisturbEnabled, forKey: .doNotDisturbEnabled)
        try container.encode(doNotDisturbFrom, forKey: .doNotDisturbFrom)
        try container.encode(doNotDisturbTo, forKey: .doNotDisturbTo)
        try container.encode(selectedCalendarHrefs, forKey: .selectedCalendarHrefs)
        try container.encode(googleEnabled, forKey: .googleEnabled)
        try container.encode(selectedGoogleCalendarIds, forKey: .selectedGoogleCalendarIds)
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
            // Same start and end time — DND effectively disabled
            return false
        } else if fromMinutes < toMinutes {
            // Same day: e.g. 13:00 - 15:00
            return currentMinutes >= fromMinutes && currentMinutes < toMinutes
        } else {
            // Overnight: e.g. 22:00 - 08:00
            return currentMinutes >= fromMinutes || currentMinutes < toMinutes
        }
    }

    // MARK: - Credentials via Keychain

    var yandexLogin: String {
        get { KeychainService.load(.yandexLogin) ?? "" }
        set {
            try? KeychainService.save(newValue, for: .yandexLogin)
            objectWillChange.send()
        }
    }

    var yandexAppPassword: String {
        get { KeychainService.load(.yandexAppPassword) ?? "" }
        set {
            try? KeychainService.save(newValue, for: .yandexAppPassword)
            objectWillChange.send()
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
