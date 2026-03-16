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
                return "\(hours) ч"
            }
            return "\(hours) ч \(remainingMinutes) мин"
        }
        return "\(minutes) мин"
    }
}

class ReminderSettings: ObservableObject, Codable {
    @Published var intervals: [ReminderInterval]
    @Published var syncIntervalMinutes: Int
    @Published var showFullScreenAlert: Bool
    @Published var playSound: Bool
    @Published var yandexLogin: String
    @Published var yandexAppPassword: String
    @Published var launchAtLogin: Bool

    enum CodingKeys: String, CodingKey {
        case intervals, syncIntervalMinutes, showFullScreenAlert, playSound
        case yandexLogin, yandexAppPassword, launchAtLogin
    }

    init() {
        self.intervals = [
            ReminderInterval(minutes: 20),
            ReminderInterval(minutes: 2)
        ]
        self.syncIntervalMinutes = 5
        self.showFullScreenAlert = true
        self.playSound = true
        self.yandexLogin = ""
        self.yandexAppPassword = ""
        self.launchAtLogin = false
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intervals = try container.decode([ReminderInterval].self, forKey: .intervals)
        syncIntervalMinutes = try container.decode(Int.self, forKey: .syncIntervalMinutes)
        showFullScreenAlert = try container.decode(Bool.self, forKey: .showFullScreenAlert)
        playSound = try container.decode(Bool.self, forKey: .playSound)
        yandexLogin = try container.decode(String.self, forKey: .yandexLogin)
        yandexAppPassword = try container.decode(String.self, forKey: .yandexAppPassword)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(syncIntervalMinutes, forKey: .syncIntervalMinutes)
        try container.encode(showFullScreenAlert, forKey: .showFullScreenAlert)
        try container.encode(playSound, forKey: .playSound)
        try container.encode(yandexLogin, forKey: .yandexLogin)
        try container.encode(yandexAppPassword, forKey: .yandexAppPassword)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
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
