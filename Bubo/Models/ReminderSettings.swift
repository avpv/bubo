import Foundation

enum BadgeCountMode: String, Codable, CaseIterable, Identifiable {
    case wholeDay
    case timeWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wholeDay: "Whole day"
        case .timeWindow: "Time window"
        }
    }
}

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
    var selectedCalendarIds: [String] { didSet { scheduleSave() } }
    var isCalendarSyncEnabled: Bool { didSet { scheduleSave() } }
    var backgroundStyle: AppBackgroundStyle { didSet { scheduleSave() } }
    var selectedSkinID: String { didSet { scheduleSave() } }
    var showBadgeCount: Bool { didSet { scheduleSave() } }

    /// Resolved skin from catalog. Use this for reading the active skin.
    var selectedSkin: SkinDefinition {
        SkinCatalog.skin(forID: selectedSkinID)
    }
    var badgeCountMode: BadgeCountMode { didSet { scheduleSave() } }
    var badgeTimeWindowHours: Int { didSet { scheduleSave() } }

    // Task-based debounced save — replaces Combine pipeline
    private var saveTask: Task<Void, Never>?

    enum CodingKeys: String, CodingKey {
        case intervals, syncIntervalMinutes, showFullScreenAlert, showSystemNotification
        case selectedCalendarIds, isCalendarSyncEnabled, backgroundStyle, selectedSkinID
        case showBadgeCount, badgeCountMode, badgeTimeWindowHours
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
        self.selectedCalendarIds = [] // empty = sync all
        self.isCalendarSyncEnabled = true
        self.backgroundStyle = .system
        self.selectedSkinID = "system"
        self.showBadgeCount = true
        self.badgeCountMode = .wholeDay
        self.badgeTimeWindowHours = 8
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intervals = try container.decode([ReminderInterval].self, forKey: .intervals)
        syncIntervalMinutes = try container.decode(Int.self, forKey: .syncIntervalMinutes)
        showFullScreenAlert = try container.decode(Bool.self, forKey: .showFullScreenAlert)
        showSystemNotification = try container.decodeIfPresent(Bool.self, forKey: .showSystemNotification) ?? true
        launchAtLogin = false
        selectedCalendarIds = try container.decodeIfPresent([String].self, forKey: .selectedCalendarIds) ?? []
        isCalendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .isCalendarSyncEnabled) ?? true
        backgroundStyle = try container.decodeIfPresent(AppBackgroundStyle.self, forKey: .backgroundStyle) ?? .system
        // Support both old "selectedSkin" key (enum rawValue) and new "selectedSkinID" key
        if let skinID = try container.decodeIfPresent(String.self, forKey: .selectedSkinID) {
            selectedSkinID = skinID
        } else {
            selectedSkinID = "system"
        }
        showBadgeCount = try container.decodeIfPresent(Bool.self, forKey: .showBadgeCount) ?? true
        badgeCountMode = try container.decodeIfPresent(BadgeCountMode.self, forKey: .badgeCountMode) ?? .wholeDay
        badgeTimeWindowHours = try container.decodeIfPresent(Int.self, forKey: .badgeTimeWindowHours) ?? 8
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(syncIntervalMinutes, forKey: .syncIntervalMinutes)
        try container.encode(showFullScreenAlert, forKey: .showFullScreenAlert)
        try container.encode(showSystemNotification, forKey: .showSystemNotification)
        try container.encode(selectedCalendarIds, forKey: .selectedCalendarIds)
        try container.encode(isCalendarSyncEnabled, forKey: .isCalendarSyncEnabled)
        try container.encode(backgroundStyle, forKey: .backgroundStyle)
        try container.encode(selectedSkinID, forKey: .selectedSkinID)
        try container.encode(showBadgeCount, forKey: .showBadgeCount)
        try container.encode(badgeCountMode, forKey: .badgeCountMode)
        try container.encode(badgeTimeWindowHours, forKey: .badgeTimeWindowHours)
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
