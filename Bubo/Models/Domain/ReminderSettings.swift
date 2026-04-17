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
    var selectedSkinID: String { didSet { scheduleSave() } }
    var selectedWallpaperID: String { didSet { scheduleSave() } }
    /// Path to a user-chosen background photo (empty = no custom photo).
    var customBackgroundPhotoPath: String { didSet { scheduleSave() } }
    /// Opacity of the custom background photo (0.0–1.0).
    var customBackgroundPhotoOpacity: Double { didSet { scheduleSave() } }
    /// Blur radius applied to the custom background photo.
    var customBackgroundPhotoBlur: Double { didSet { scheduleSave() } }

    var showBadgeCount: Bool { didSet { scheduleSave() } }

    /// Resolved skin from catalog. Use this for reading the active skin.
    var selectedSkin: SkinDefinition {
        SkinCatalog.skin(forID: selectedSkinID)
    }

    /// Resolved wallpaper from catalog.
    var selectedWallpaper: WallpaperDefinition {
        WallpaperCatalog.wallpaper(forID: selectedWallpaperID)
    }
    var badgeCountMode: BadgeCountMode { didSet { scheduleSave() } }
    var badgeTimeWindowHours: Int { didSet { scheduleSave() } }

    // Apple Reminders integration
    var isRemindersSyncEnabled: Bool { didSet { scheduleSave() } }
    /// Which Reminders lists to import (empty = all).
    var selectedRemindersListIds: [String] { didSet { scheduleSave() } }
    /// When true, completing a task in Bubo also marks it done in Apple Reminders.
    var remindersCompletionSync: Bool { didSet { scheduleSave() } }
    /// Default duration in minutes for imported reminders (Apple Reminders has no duration concept).
    var remindersDefaultDurationMinutes: Int { didSet { scheduleSave() } }
    /// When true, new backlog tasks created in Bubo are exported to Apple Reminders
    /// so they appear on all iCloud-connected devices (iPhone, iPad, etc.).
    var remindersExportEnabled: Bool { didSet { scheduleSave() } }
    /// The Reminders list to create exported tasks in. nil = default list.
    var remindersExportListId: String? { didSet { scheduleSave() } }
    /// When true, removing a task in Bubo also deletes its linked reminder.
    /// Opt-in for safety — imported tasks get added to `dismissedReminderIds` instead.
    var remindersDeletionSync: Bool { didSet { scheduleSave() } }

    // World Clock
    var isWorldClockEnabled: Bool { didSet { scheduleSave() } }
    var worldClockCityIDs: [String] { didSet { scheduleSave() } }

    // Task-based debounced save — replaces Combine pipeline
    private var saveTask: Task<Void, Never>?

    /// Prevents didSet -> save -> push loop when reloading cloud data.
    private var isReloadingFromCloud = false
    private var cloudSyncObserver: Any?

    enum CodingKeys: String, CodingKey {
        case intervals, syncIntervalMinutes, showFullScreenAlert, showSystemNotification
        case selectedCalendarIds, isCalendarSyncEnabled, selectedSkinID
        case selectedWallpaperID
        case customBackgroundPhotoPath, customBackgroundPhotoOpacity, customBackgroundPhotoBlur
        case showBadgeCount, badgeCountMode, badgeTimeWindowHours
        case isRemindersSyncEnabled, selectedRemindersListIds, remindersCompletionSync, remindersDefaultDurationMinutes
        case remindersExportEnabled, remindersExportListId, remindersDeletionSync
        case isWorldClockEnabled, worldClockCityIDs
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
        self.selectedSkinID = "system"
        self.selectedWallpaperID = "none"
        self.customBackgroundPhotoPath = ""
        self.customBackgroundPhotoOpacity = 0.25
        self.customBackgroundPhotoBlur = 2

        self.showBadgeCount = true
        self.badgeCountMode = .wholeDay
        self.badgeTimeWindowHours = 8
        self.isRemindersSyncEnabled = false
        self.selectedRemindersListIds = []
        self.remindersCompletionSync = true
        self.remindersDefaultDurationMinutes = 60
        self.remindersExportEnabled = false
        self.remindersExportListId = nil
        self.remindersDeletionSync = false
        self.isWorldClockEnabled = false
        self.worldClockCityIDs = []
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
        selectedSkinID = try container.decodeIfPresent(String.self, forKey: .selectedSkinID) ?? "system"
        selectedWallpaperID = try container.decodeIfPresent(String.self, forKey: .selectedWallpaperID) ?? "none"
        customBackgroundPhotoPath = try container.decodeIfPresent(String.self, forKey: .customBackgroundPhotoPath) ?? ""
        customBackgroundPhotoOpacity = try container.decodeIfPresent(Double.self, forKey: .customBackgroundPhotoOpacity) ?? 0.25
        customBackgroundPhotoBlur = try container.decodeIfPresent(Double.self, forKey: .customBackgroundPhotoBlur) ?? 2

        showBadgeCount = try container.decodeIfPresent(Bool.self, forKey: .showBadgeCount) ?? true
        badgeCountMode = try container.decodeIfPresent(BadgeCountMode.self, forKey: .badgeCountMode) ?? .wholeDay
        badgeTimeWindowHours = try container.decodeIfPresent(Int.self, forKey: .badgeTimeWindowHours) ?? 8
        isRemindersSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .isRemindersSyncEnabled) ?? false
        selectedRemindersListIds = try container.decodeIfPresent([String].self, forKey: .selectedRemindersListIds) ?? []
        remindersCompletionSync = try container.decodeIfPresent(Bool.self, forKey: .remindersCompletionSync) ?? true
        remindersDefaultDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .remindersDefaultDurationMinutes) ?? 60
        remindersExportEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersExportEnabled) ?? false
        remindersExportListId = try container.decodeIfPresent(String.self, forKey: .remindersExportListId)
        remindersDeletionSync = try container.decodeIfPresent(Bool.self, forKey: .remindersDeletionSync) ?? false
        isWorldClockEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWorldClockEnabled) ?? false
        worldClockCityIDs = try container.decodeIfPresent([String].self, forKey: .worldClockCityIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(syncIntervalMinutes, forKey: .syncIntervalMinutes)
        try container.encode(showFullScreenAlert, forKey: .showFullScreenAlert)
        try container.encode(showSystemNotification, forKey: .showSystemNotification)
        try container.encode(selectedCalendarIds, forKey: .selectedCalendarIds)
        try container.encode(isCalendarSyncEnabled, forKey: .isCalendarSyncEnabled)
        try container.encode(selectedSkinID, forKey: .selectedSkinID)
        try container.encode(selectedWallpaperID, forKey: .selectedWallpaperID)
        try container.encode(customBackgroundPhotoPath, forKey: .customBackgroundPhotoPath)
        try container.encode(customBackgroundPhotoOpacity, forKey: .customBackgroundPhotoOpacity)
        try container.encode(customBackgroundPhotoBlur, forKey: .customBackgroundPhotoBlur)

        try container.encode(showBadgeCount, forKey: .showBadgeCount)
        try container.encode(badgeCountMode, forKey: .badgeCountMode)
        try container.encode(badgeTimeWindowHours, forKey: .badgeTimeWindowHours)
        try container.encode(isRemindersSyncEnabled, forKey: .isRemindersSyncEnabled)
        try container.encode(selectedRemindersListIds, forKey: .selectedRemindersListIds)
        try container.encode(remindersCompletionSync, forKey: .remindersCompletionSync)
        try container.encode(remindersDefaultDurationMinutes, forKey: .remindersDefaultDurationMinutes)
        try container.encode(remindersExportEnabled, forKey: .remindersExportEnabled)
        try container.encodeIfPresent(remindersExportListId, forKey: .remindersExportListId)
        try container.encode(remindersDeletionSync, forKey: .remindersDeletionSync)
        try container.encode(isWorldClockEnabled, forKey: .isWorldClockEnabled)
        try container.encode(worldClockCityIDs, forKey: .worldClockCityIDs)
    }

    private func scheduleSave() {
        guard !isReloadingFromCloud else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
            NotificationCenter.default.post(name: Self.settingsDidChange, object: nil)
        }
    }

    private static let persistenceKey = "ReminderSettings"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
            CloudSyncService.shared.push(Self.persistenceKey)
        }
    }

    static func load() -> ReminderSettings {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let settings = try? JSONDecoder().decode(ReminderSettings.self, from: data) else {
            let settings = ReminderSettings()
            settings.setupCloudSync()
            return settings
        }
        settings.setupCloudSync()
        return settings
    }

    // MARK: - Cloud Sync

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String,
                  key == ReminderSettings.persistenceKey else { return }
            self?.reloadFromCloud()
        }
    }

    private func reloadFromCloud() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
              let fresh = try? JSONDecoder().decode(ReminderSettings.self, from: data)
        else { return }

        isReloadingFromCloud = true
        defer { isReloadingFromCloud = false }

        intervals = fresh.intervals
        syncIntervalMinutes = fresh.syncIntervalMinutes
        showFullScreenAlert = fresh.showFullScreenAlert
        showSystemNotification = fresh.showSystemNotification
        selectedCalendarIds = fresh.selectedCalendarIds
        isCalendarSyncEnabled = fresh.isCalendarSyncEnabled
        selectedSkinID = fresh.selectedSkinID
        selectedWallpaperID = fresh.selectedWallpaperID
        customBackgroundPhotoPath = fresh.customBackgroundPhotoPath
        customBackgroundPhotoOpacity = fresh.customBackgroundPhotoOpacity
        customBackgroundPhotoBlur = fresh.customBackgroundPhotoBlur
        showBadgeCount = fresh.showBadgeCount
        badgeCountMode = fresh.badgeCountMode
        badgeTimeWindowHours = fresh.badgeTimeWindowHours
        isRemindersSyncEnabled = fresh.isRemindersSyncEnabled
        selectedRemindersListIds = fresh.selectedRemindersListIds
        remindersCompletionSync = fresh.remindersCompletionSync
        remindersDefaultDurationMinutes = fresh.remindersDefaultDurationMinutes
        remindersExportEnabled = fresh.remindersExportEnabled
        remindersExportListId = fresh.remindersExportListId
        remindersDeletionSync = fresh.remindersDeletionSync
        isWorldClockEnabled = fresh.isWorldClockEnabled
        worldClockCityIDs = fresh.worldClockCityIDs

        NotificationCenter.default.post(name: Self.settingsDidChange, object: nil)
    }
}
