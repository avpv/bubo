import Foundation

public enum BadgeCountMode: String, Codable, CaseIterable, Identifiable {
    case wholeDay
    case timeWindow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wholeDay: "Whole day"
        case .timeWindow: "Time window"
        }
    }
}

public struct ReminderInterval: Identifiable, Codable, Hashable {
    public let id: UUID
    public var minutes: Int
    public var isEnabled: Bool

    public init(minutes: Int, isEnabled: Bool = true) {
        self.id = UUID()
        self.minutes = minutes
        self.isEnabled = isEnabled
    }

    public var displayText: String {
        // PRINCIPLES §3 — non-breaking space between number and unit so
        // «3 h 15 min» never breaks mid-quantity. Mirrors the shared
        // `DS.formatMinutes` helper (Views layer); we can't import DS
        // from Models, so the canonical form is inlined here.
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes == 0 {
                return "\(hours)\u{00A0}h"
            }
            return "\(hours)\u{00A0}h\u{00A0}\(remainingMinutes)\u{00A0}min"
        }
        return "\(minutes)\u{00A0}min"
    }
}

/// Bubo-native project. Lives independently from Apple Reminders so users
/// who don't sync with Reminders.app still have a way to group backlog
/// tasks by project. `BacklogTask.context` carries the project name (same
/// vocabulary as for Reminders-list-backed projects), so filtering and
/// "active project" semantics are identical regardless of source.
public struct LocalProject: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Discriminated view of `ReminderSettings.activeProjectListId`. The raw
/// storage stays a single optional string for back-compat with serialized
/// settings; this enum decodes it into "all tasks" / local Bubo project /
/// Apple Reminders list. Local ids are persisted as `"local:<UUID>"` so a
/// device without EventKit access still round-trips them through CloudKit.
public enum ActiveProject: Equatable, Sendable {
    case all
    case local(UUID)
    case remindersList(String)

    public static let localPrefix = "local:"

    public init(rawValue: String?) {
        guard let raw = rawValue, !raw.isEmpty else { self = .all; return }
        if raw.hasPrefix(Self.localPrefix),
           let uuid = UUID(uuidString: String(raw.dropFirst(Self.localPrefix.count))) {
            self = .local(uuid)
        } else {
            self = .remindersList(raw)
        }
    }

    public var rawValue: String? {
        switch self {
        case .all: return nil
        case .local(let id): return Self.localPrefix + id.uuidString
        case .remindersList(let id): return id
        }
    }
}



@Observable
public class ReminderSettings: Codable {
    public static let settingsDidChange = Notification.Name("ReminderSettingsDidChange")

    public var intervals: [ReminderInterval] { didSet { scheduleSave() } }
    public var syncIntervalMinutes: Int { didSet { scheduleSave() } }
    public var showFullScreenAlert: Bool { didSet { scheduleSave() } }
    public var showSystemNotification: Bool { didSet { scheduleSave() } }
    public var launchAtLogin: Bool
    public var selectedCalendarIds: [String] { didSet { scheduleSave() } }
    public var isCalendarSyncEnabled: Bool { didSet { scheduleSave() } }
    public var selectedSkinID: String { didSet { scheduleSave() } }
    public var selectedWallpaperID: String { didSet { scheduleSave() } }
    /// Path to a user-chosen background photo (empty = no custom photo).
    public var customBackgroundPhotoPath: String { didSet { scheduleSave() } }
    /// Opacity of the custom background photo (0.0–1.0).
    public var customBackgroundPhotoOpacity: Double { didSet { scheduleSave() } }
    /// Blur radius applied to the custom background photo.
    public var customBackgroundPhotoBlur: Double { didSet { scheduleSave() } }

    public var showBadgeCount: Bool { didSet { scheduleSave() } }

    // The `selectedSkin` convenience that resolves `selectedSkinID` to a
    // `SkinDefinition` lives in `Presentation/Skins/ReminderSettings+Skin.swift`,
    // and the `selectedWallpaper` companion lives in
    // `Presentation/Skins/Wallpaper/ReminderSettings+Wallpaper.swift`, so
    // this domain type doesn't depend on the SwiftUI-backed catalogs.

    public var badgeCountMode: BadgeCountMode { didSet { scheduleSave() } }
    public var badgeTimeWindowHours: Int { didSet { scheduleSave() } }

    // Apple Reminders integration
    public var isRemindersSyncEnabled: Bool { didSet { scheduleSave() } }
    /// Which Reminders lists to import (empty = all).
    public var selectedRemindersListIds: [String] { didSet { scheduleSave() } }
    /// When true, completing a task in Bubo also marks it done in Apple Reminders.
    public var remindersCompletionSync: Bool { didSet { scheduleSave() } }
    /// Default duration in minutes for imported reminders (Apple Reminders has no duration concept).
    public var remindersDefaultDurationMinutes: Int { didSet { scheduleSave() } }
    /// When true, new backlog tasks created in Bubo are exported to Apple Reminders
    /// so they appear on all iCloud-connected devices (iPhone, iPad, etc.).
    public var remindersExportEnabled: Bool { didSet { scheduleSave() } }
    /// The Reminders list to create exported tasks in. nil = default list.
    public var remindersExportListId: String? { didSet { scheduleSave() } }
    /// When true, removing a task in Bubo also deletes its linked reminder.
    /// Opt-in for safety — imported tasks get added to `dismissedReminderIds` instead.
    public var remindersDeletionSync: Bool { didSet { scheduleSave() } }
    /// When true, scheduling a linked task installs `EKAlarm`s on the
    /// underlying reminder so iPhone / iPad ring at the scheduled time.
    /// Opt-in — touches the user's phone notification surface, so we
    /// don't enable it without consent. Always anchors at least one
    /// alarm at the scheduled moment; lead times below stack on top.
    public var remindersScheduleAlarms: Bool { didSet { scheduleSave() } }
    /// Lead-time alarms added in addition to the at-time alarm when
    /// `remindersScheduleAlarms` is on. Reuses the same `ReminderInterval`
    /// shape as calendar-event reminders so the UI / serialization
    /// vocabulary stays consistent.
    public var remindersScheduleAlarmLeadMinutes: [ReminderInterval] { didSet { scheduleSave() } }

    /// Active project the user is focused on, drawn from the backlog
    /// header's project picker. Stored as a single string for back-compat
    /// with previously-serialized settings, but decoded through
    /// `ActiveProject` (see helper below):
    ///   - `nil`            → `.all`              (no filter)
    ///   - `"local:<UUID>"` → `.local(id)`        (Bubo-native project)
    ///   - any other value  → `.remindersList(id)` (EK calendar id)
    /// When non-`.all`, the backlog filters rows to that project and new
    /// tasks created from the inline add-field land there (overriding the
    /// global export list for the duration of the focus).
    public var activeProjectListId: String? { didSet { scheduleSave() } }

    /// Bubo-native projects that live independently of Apple Reminders.
    /// Visible in the backlog project picker even when EventKit sync is
    /// off / not granted, so users can group tasks without needing the
    /// Reminders.app at all. Persisted through CloudKit alongside the
    /// rest of `ReminderSettings`.
    public var localProjects: [LocalProject] { didSet { scheduleSave() } }

    // World Clock
    public var isWorldClockEnabled: Bool { didSet { scheduleSave() } }
    public var worldClockCityIDs: [String] { didSet { scheduleSave() } }

    // Task-based debounced save — replaces Combine pipeline
    private var saveTask: Task<Void, Never>?

    /// Prevents didSet -> save -> push loop when reloading cloud data.
    private var isReloadingFromCloud = false
    private var cloudSyncObserver: Any?

    public enum CodingKeys: String, CodingKey {
        case intervals, syncIntervalMinutes, showFullScreenAlert, showSystemNotification
        case selectedCalendarIds, isCalendarSyncEnabled, selectedSkinID
        case selectedWallpaperID
        case customBackgroundPhotoPath, customBackgroundPhotoOpacity, customBackgroundPhotoBlur
        case showBadgeCount, badgeCountMode, badgeTimeWindowHours
        case isRemindersSyncEnabled, selectedRemindersListIds, remindersCompletionSync, remindersDefaultDurationMinutes
        case remindersExportEnabled, remindersExportListId, remindersDeletionSync
        case remindersScheduleAlarms, remindersScheduleAlarmLeadMinutes
        case activeProjectListId, localProjects
        case isWorldClockEnabled, worldClockCityIDs
    }

    public init() {
        let initialIntervals = [
            ReminderInterval(minutes: 20),
            ReminderInterval(minutes: 2)
        ]
        self.intervals = initialIntervals
        self.syncIntervalMinutes = 5
        self.showFullScreenAlert = true
        self.showSystemNotification = true
        self.launchAtLogin = false
        self.selectedCalendarIds = [] // empty = sync all
        self.isCalendarSyncEnabled = true
        self.selectedSkinID = "daybreak"
        // Default wallpaper is the skin-paired backdrop. Fresh installs
        // see the active skin's gravity-of-light owning the canvas;
        // existing users keep whatever id they previously persisted.
        self.selectedWallpaperID = "auto"
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
        self.remindersScheduleAlarms = false
        // Seed the iPhone-alarm lead-times with the same intervals the user
        // has configured for in-app meeting reminders. Treats the meeting
        // intervals as «my mental model of how far ahead I want a heads-up»
        // — once both lists exist on the settings object the user can
        // diverge them freely, but the first-launch default mirrors what
        // they already use for events instead of starting empty.
        self.remindersScheduleAlarmLeadMinutes = Self.copyIntervals(initialIntervals)
        self.activeProjectListId = nil
        self.localProjects = []
        self.isWorldClockEnabled = false
        self.worldClockCityIDs = []
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedIntervals = try container.decode([ReminderInterval].self, forKey: .intervals)
        intervals = decodedIntervals
        syncIntervalMinutes = try container.decode(Int.self, forKey: .syncIntervalMinutes)
        showFullScreenAlert = try container.decode(Bool.self, forKey: .showFullScreenAlert)
        showSystemNotification = try container.decodeIfPresent(Bool.self, forKey: .showSystemNotification) ?? true
        launchAtLogin = false
        selectedCalendarIds = try container.decodeIfPresent([String].self, forKey: .selectedCalendarIds) ?? []
        isCalendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .isCalendarSyncEnabled) ?? true
        selectedSkinID = try container.decodeIfPresent(String.self, forKey: .selectedSkinID) ?? "daybreak"
        selectedWallpaperID = try container.decodeIfPresent(String.self, forKey: .selectedWallpaperID) ?? "auto"
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
        remindersScheduleAlarms = try container.decodeIfPresent(Bool.self, forKey: .remindersScheduleAlarms) ?? false
        // Existing users upgrading from a build without this key fall back
        // to a copy of their meeting reminder intervals — same rationale
        // as the fresh-install default in `init()`.
        remindersScheduleAlarmLeadMinutes = try container.decodeIfPresent(
            [ReminderInterval].self,
            forKey: .remindersScheduleAlarmLeadMinutes
        ) ?? Self.copyIntervals(decodedIntervals)
        activeProjectListId = try container.decodeIfPresent(String.self, forKey: .activeProjectListId)
        localProjects = try container.decodeIfPresent([LocalProject].self, forKey: .localProjects) ?? []
        isWorldClockEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWorldClockEnabled) ?? false
        worldClockCityIDs = try container.decodeIfPresent([String].self, forKey: .worldClockCityIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
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
        try container.encode(remindersScheduleAlarms, forKey: .remindersScheduleAlarms)
        try container.encode(remindersScheduleAlarmLeadMinutes, forKey: .remindersScheduleAlarmLeadMinutes)
        try container.encodeIfPresent(activeProjectListId, forKey: .activeProjectListId)
        try container.encode(localProjects, forKey: .localProjects)
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

    /// Build a fresh `[ReminderInterval]` from another list, copying
    /// `minutes` and `isEnabled` but generating new ids. Used so the
    /// iPhone-alarm lead-times default to the meeting reminders without
    /// sharing identifiers — they're independent lists from this point on.
    private static func copyIntervals(_ source: [ReminderInterval]) -> [ReminderInterval] {
        source.map { ReminderInterval(minutes: $0.minutes, isEnabled: $0.isEnabled) }
    }

    private static let persistenceKey = "ReminderSettings"

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
            NotificationCenter.default.post(
                name: DomainCloudSync.shouldPushKey,
                object: Self.persistenceKey
            )
        }
    }

    public static func load() -> ReminderSettings {
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
            forName: DomainCloudSync.didReceiveRemoteChange,
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
        remindersScheduleAlarms = fresh.remindersScheduleAlarms
        remindersScheduleAlarmLeadMinutes = fresh.remindersScheduleAlarmLeadMinutes
        activeProjectListId = fresh.activeProjectListId
        localProjects = fresh.localProjects
        isWorldClockEnabled = fresh.isWorldClockEnabled
        worldClockCityIDs = fresh.worldClockCityIDs

        NotificationCenter.default.post(name: Self.settingsDidChange, object: nil)
    }
}

// MARK: - Active project helpers

public extension ReminderSettings {
    /// Typed view of `activeProjectListId`. Reading decodes the raw string;
    /// writing re-encodes it (which triggers the usual `didSet`-driven save).
    var activeProject: ActiveProject {
        get { ActiveProject(rawValue: activeProjectListId) }
        set { activeProjectListId = newValue.rawValue }
    }

    /// Apple Reminders calendar id of the active project, or `nil` for
    /// `.all` and `.local`. Used by the export path to pick a target list:
    /// local projects don't map to any EK list, so the caller falls back
    /// to `remindersExportListId`.
    var activeRemindersListId: String? {
        if case .remindersList(let id) = activeProject { return id }
        return nil
    }

    // The `activeProjectTitle(remindersService:)` lookup that resolves a
    // `.remindersList(id)` to its EK calendar title needs the
    // `AppleRemindersService` from the Bubo target, so it lives in
    // `Application/Reminders/ReminderSettings+ActiveProject.swift`.

    /// Adds a new local project with the trimmed name, makes it active,
    /// and returns it. Empty / whitespace-only names are rejected.
    /// Duplicate names (case-insensitive, against existing local projects)
    /// are coalesced — we re-select the existing project instead of
    /// creating a second one with the same `BacklogTask.context` value.
    @discardableResult
    func addLocalProject(name: String) -> LocalProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = localProjects.first(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            activeProject = .local(existing.id)
            return existing
        }
        let project = LocalProject(name: trimmed)
        localProjects.append(project)
        activeProject = .local(project.id)
        return project
    }
}
