import SwiftUI
import SwiftData

private class MenuBarIconCache {
    var count: Int = -1
    var skinID: String = ""
    var image: NSImage?
}
private let sharedIconCache = MenuBarIconCache()

@main
struct BuboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings: ReminderSettings
    @State private var reminderService: ReminderService
    @State private var networkMonitor = NetworkMonitor()
    @State private var optimizerService: OptimizerService
    @State private var agentService = AgentService()
    @State private var remindersSyncService: RemindersSyncService

    /// Shared container for event caches + reminder overrides. Always
    /// local — the event cache is a device-specific scratch pad and the
    /// `@Attribute(.unique)` constraints on these models are incompatible
    /// with CloudKit mirroring anyway.
    private let modelContainer: ModelContainer

    /// Dedicated container for backlog tasks. Lives in its own `.store`
    /// file so it can opt into CloudKit without dragging the event models
    /// (which carry `@Attribute(.unique)`) along. One-time migration from
    /// the legacy combined store happens in `init` the first time a user
    /// launches a build with the split containers.
    private let backlogContainer: ModelContainer

    /// UserDefaults flag controlling whether the backlog store opts into
    /// CloudKit-backed SwiftData sync. Defaults to `false` — users can
    /// flip it on from Settings; on failure (signed-out iCloud, CloudKit
    /// schema not yet deployed) we fall back to a local-only container so
    /// the app still launches.
    static let cloudSyncPreferenceKey = "BuboBacklogCloudSyncEnabled"

    /// Tracks whether the one-time "split the combined store into Events +
    /// Backlog" migration has already run.
    static let backlogMigrationDoneKey = "BuboBacklogSplitMigrationDone"

    /// URL of the dedicated backlog store.
    static let backlogStoreURL: URL = URL.applicationSupportDirectory
        .appending(path: "Backlog.store")

    /// Build the events-only container (always local).
    private static func makeEventsContainer() throws -> ModelContainer {
        let schema = Schema([
            PersistedLocalEvent.self,
            PersistedCachedEvent.self,
            PersistedExcludedOccurrence.self,
            PersistedReminderOverride.self,
        ])
        return try ModelContainer(for: schema)
    }

    /// Build the backlog-only container. CloudKit is opt-in — on failure
    /// the caller retries with `.none` so a missing iCloud account never
    /// blocks app launch.
    private static func makeBacklogContainer(cloudEnabled: Bool) throws -> ModelContainer {
        let schema = Schema([PersistedBacklogTask.self])
        let config = ModelConfiguration(
            schema: schema,
            url: backlogStoreURL,
            cloudKitDatabase: cloudEnabled ? .automatic : .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Open the legacy combined schema (events + backlog) at the default
    /// store URL. Used once, during migration, to read out any pre-split
    /// backlog rows before we swap to the events-only schema for that store.
    private static func makeLegacyContainer() throws -> ModelContainer {
        let schema = Schema([
            PersistedLocalEvent.self,
            PersistedCachedEvent.self,
            PersistedExcludedOccurrence.self,
            PersistedReminderOverride.self,
            PersistedBacklogTask.self,
        ])
        return try ModelContainer(for: schema)
    }

    /// Copy any backlog rows that still live in the legacy combined store
    /// into the new dedicated backlog container. Idempotent — the migration
    /// flag prevents a second run, and in-flight rows are skipped if the
    /// new store already contains the same taskId (CloudKit may have beaten
    /// the migration to the punch).
    private static func migrateLegacyBacklogIfNeeded(into backlogContainer: ModelContainer) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: backlogMigrationDoneKey) == false else { return }

        // If there's no legacy combined store, there's nothing to migrate.
        let legacyURL = URL.applicationSupportDirectory.appending(path: "default.store")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            defaults.set(true, forKey: backlogMigrationDoneKey)
            return
        }

        guard let legacy = try? makeLegacyContainer() else {
            // Can't read the legacy store — don't mark migration done so
            // we can retry on next launch.
            return
        }
        let legacyContext = ModelContext(legacy)
        let rows = (try? legacyContext.fetch(FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder)]
        ))) ?? []

        if rows.isEmpty {
            defaults.set(true, forKey: backlogMigrationDoneKey)
            return
        }

        // Copy each row into the new backlog store. Use the BacklogTask
        // round-trip to avoid carrying over SwiftData identity, which is
        // tied to the source container.
        let targetContext = ModelContext(backlogContainer)
        let existing = (try? targetContext.fetch(FetchDescriptor<PersistedBacklogTask>())) ?? []
        let existingIds = Set(existing.map(\.taskId))
        for (index, row) in rows.enumerated() where !existingIds.contains(row.taskId) {
            let task = row.toBacklogTask()
            targetContext.insert(PersistedBacklogTask(from: task, sortOrder: index))
        }
        try? targetContext.save()

        // Now drop the legacy rows so the old store doesn't keep ghosts
        // that CloudKit will overwrite with stale copies later.
        for row in rows {
            legacyContext.delete(row)
        }
        try? legacyContext.save()

        defaults.set(true, forKey: backlogMigrationDoneKey)
    }

    init() {
        let defaults = UserDefaults.standard
        let cloudPreference = defaults.object(forKey: Self.cloudSyncPreferenceKey) as? Bool ?? false

        // Events container — local, always recoverable (cache rebuilds
        // from EventKit on next sync).
        let eventsContainer: ModelContainer
        do {
            eventsContainer = try Self.makeEventsContainer()
        } catch {
            // Schema migration failed — delete the corrupted default store
            // and retry. Data loss here is the calendar cache, which
            // rebuilds automatically on next sync.
            let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
            try? FileManager.default.removeItem(at: storeURL)
            for suffix in ["-wal", "-shm"] {
                let sidecar = storeURL.deletingPathExtension()
                    .appendingPathExtension(storeURL.pathExtension + suffix)
                try? FileManager.default.removeItem(at: sidecar)
            }
            do {
                eventsContainer = try Self.makeEventsContainer()
            } catch {
                fatalError("Failed to create events ModelContainer after reset: \(error)")
            }
        }
        self.modelContainer = eventsContainer

        // Backlog container — can opt into CloudKit. If iCloud build fails
        // we fall through to local-only so the app still launches.
        let backlog: ModelContainer
        do {
            backlog = try Self.makeBacklogContainer(cloudEnabled: cloudPreference)
        } catch {
            if cloudPreference, let retry = try? Self.makeBacklogContainer(cloudEnabled: false) {
                backlog = retry
            } else {
                // Backlog store is corrupt or CloudKit is firmly rejecting
                // the schema — delete and retry so the user at least gets
                // a working (if empty) backlog.
                try? FileManager.default.removeItem(at: Self.backlogStoreURL)
                for suffix in ["-wal", "-shm"] {
                    let sidecar = Self.backlogStoreURL.deletingPathExtension()
                        .appendingPathExtension(Self.backlogStoreURL.pathExtension + suffix)
                    try? FileManager.default.removeItem(at: sidecar)
                }
                do {
                    backlog = try Self.makeBacklogContainer(cloudEnabled: false)
                } catch {
                    fatalError("Failed to create backlog ModelContainer after reset: \(error)")
                }
            }
        }
        self.backlogContainer = backlog

        // One-shot migration of legacy combined-store backlog rows into the
        // new dedicated store. No-op on second launch thanks to the flag.
        Self.migrateLegacyBacklogIfNeeded(into: backlog)

        // Surface CloudKit sync state to the UI. Events from the shared
        // `NSPersistentCloudKitContainer` are posted globally, so we don't
        // need to hand the container reference in — the monitor just needs
        // to be alive before the first import/export fires.
        if cloudPreference {
            CloudKitSyncMonitor.shared.start(
                containerIdentifier: "iCloud.\(Bundle.main.bundleIdentifier ?? "")"
            )
        }

        let s = ReminderSettings.load()
        _settings = State(wrappedValue: s)
        _reminderService = State(wrappedValue: ReminderService(settings: s, modelContainer: eventsContainer))

        let optimizer = OptimizerService()
        let backlogService = BacklogService(modelContainer: backlog)
        optimizer.backlogService = backlogService
        optimizer.energyCheckInService = EnergyCheckInService()
        _optimizerService = State(wrappedValue: optimizer)

        _remindersSyncService = State(wrappedValue: RemindersSyncService(
            settings: s,
            backlogService: backlogService
        ))
    }

    private func drawOwl(in ctx: CGContext, size s: CGFloat, color: CGColor) {
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        ctx.setFillColor(color)

        // Owl body (rounded rect)
        let bodyRect = CGRect(x: s * 0.15, y: s * 0.05, width: s * 0.7, height: s * 0.7)
        let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
        ctx.addPath(bodyPath)
        ctx.fillPath()

        // Ears (two triangles)
        ctx.move(to: CGPoint(x: s * 0.15, y: s * 0.65))
        ctx.addLine(to: CGPoint(x: s * 0.28, y: s * 0.92))
        ctx.addLine(to: CGPoint(x: s * 0.38, y: s * 0.7))
        ctx.closePath()
        ctx.fillPath()

        ctx.move(to: CGPoint(x: s * 0.85, y: s * 0.65))
        ctx.addLine(to: CGPoint(x: s * 0.72, y: s * 0.92))
        ctx.addLine(to: CGPoint(x: s * 0.62, y: s * 0.7))
        ctx.closePath()
        ctx.fillPath()

        // Eyes (cut out circles — clear)
        ctx.setBlendMode(.clear)
        let eyeR = s * 0.1
        let eyeY = s * 0.48
        ctx.fillEllipse(in: CGRect(x: s * 0.28, y: eyeY, width: eyeR * 2, height: eyeR * 2))
        ctx.fillEllipse(in: CGRect(x: s * 0.52, y: eyeY, width: eyeR * 2, height: eyeR * 2))

        // Pupils (fill back)
        ctx.setBlendMode(.normal)
        ctx.setFillColor(color)
        let pupilR = s * 0.05
        let pupilY = eyeY + eyeR - pupilR
        ctx.fillEllipse(in: CGRect(x: s * 0.33, y: pupilY, width: pupilR * 2, height: pupilR * 2))
        ctx.fillEllipse(in: CGRect(x: s * 0.57, y: pupilY, width: pupilR * 2, height: pupilR * 2))

        // Small beak
        ctx.move(to: CGPoint(x: s * 0.44, y: s * 0.4))
        ctx.addLine(to: CGPoint(x: s * 0.5, y: s * 0.32))
        ctx.addLine(to: CGPoint(x: s * 0.56, y: s * 0.4))
        ctx.closePath()
        ctx.fillPath()
    }

    private var useSkinIcon: Bool {
        let skinID = settings.selectedSkinID
        return skinID != "system" && skinID != "classic"
    }

    private func resolvedIconColor(isDark: Bool) -> CGColor {
        let base = NSColor(settings.selectedSkin.accentColor)
            .usingColorSpace(.sRGB) ?? NSColor(settings.selectedSkin.accentColor)

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Relative luminance approximation (rec. 709)
        let r = base.redComponent, g = base.greenComponent, bl = base.blueComponent
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * bl

        if isDark {
            if lum < 0.25 {
                let adjusted = NSColor(hue: h, saturation: s * 0.8, brightness: max(b, 0.65), alpha: a)
                return adjusted.cgColor
            }
        } else {
            if lum > 0.7 {
                let adjusted = NSColor(hue: h, saturation: max(s, 0.5), brightness: min(b, 0.55), alpha: a)
                return adjusted.cgColor
            }
        }
        return base.cgColor
    }

    private var menuBarIcon: NSImage {
        let currentSkinID = settings.selectedSkinID
        if sharedIconCache.count == 0, sharedIconCache.skinID == currentSkinID, let img = sharedIconCache.image {
            return img
        }

        let size = NSSize(width: 18, height: 18)
        let useCustom = useSkinIcon
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color: CGColor = useCustom
                ? self.resolvedIconColor(isDark: isDark)
                : (isDark ? NSColor.white.cgColor : NSColor.black.cgColor)
            self.drawOwl(in: ctx, size: rect.width, color: color)
            return true
        }
        image.isTemplate = !useSkinIcon

        sharedIconCache.count = 0
        sharedIconCache.skinID = currentSkinID
        sharedIconCache.image = image

        return image
    }

    private var badgeCount: Int {
        reminderService.badgeCount
    }

    private func menuBarIconWithBadge(count: Int) -> NSImage {
        guard count > 0 else { return menuBarIcon }

        let currentSkinID = settings.selectedSkinID
        if sharedIconCache.count == count, sharedIconCache.skinID == currentSkinID, let img = sharedIconCache.image {
            return img
        }

        let iconSize: CGFloat = 18
        let badgeText = (count > 99 ? "99+" : "\(count)") as NSString
        let fontSize: CGFloat = 8.5
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = badgeText.size(withAttributes: attrs)
        let badgeDiameter: CGFloat = 12
        let badgeWidth = max(badgeDiameter, textSize.width + 6)

        let overlapX: CGFloat = badgeWidth * 0.3
        let overlapY: CGFloat = badgeDiameter * 0.35
        let totalWidth = iconSize + badgeWidth - overlapX
        let bottomOverflow = max(0, overlapY - 1)
        let totalHeight = iconSize + bottomOverflow

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let iconColor: CGColor = self.useSkinIcon
                ? self.resolvedIconColor(isDark: isDark)
                : (isDark ? NSColor.white.cgColor : NSColor.black.cgColor)

            ctx.saveGState()
            ctx.translateBy(x: 0, y: bottomOverflow + 2)
            self.drawOwl(in: ctx, size: iconSize, color: iconColor)
            ctx.restoreGState()

            let badgeX = iconSize - overlapX
            let badgeY: CGFloat = bottomOverflow - overlapY + 1
            let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeDiameter)
            let cutoutPadding: CGFloat = 1.5
            let cutoutRect = badgeRect.insetBy(dx: -cutoutPadding, dy: -cutoutPadding)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            let cutoutPath = NSBezierPath(roundedRect: cutoutRect, xRadius: (badgeDiameter / 2) + cutoutPadding, yRadius: (badgeDiameter / 2) + cutoutPadding)
            cutoutPath.fill()
            ctx.restoreGState()

            let badgeColor = NSColor.systemRed

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeDiameter / 2, yRadius: badgeDiameter / 2)
            badgeColor.setFill()
            badgePath.fill()
            ctx.restoreGState()

            badgeColor.setFill()
            badgePath.fill()

            let highlightRect = NSRect(x: badgeX + 1.5, y: badgeY + badgeDiameter * 0.5, width: badgeWidth - 3, height: badgeDiameter * 0.4)
            let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 3, yRadius: 3)
            NSColor.white.withAlphaComponent(0.15).setFill()
            highlightPath.fill()

            let textX = badgeX + (badgeWidth - textSize.width) / 2
            let textY = badgeY + (badgeDiameter - textSize.height) / 2
            badgeText.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            return true
        }
        image.isTemplate = false

        sharedIconCache.count = count
        sharedIconCache.skinID = currentSkinID
        sharedIconCache.image = image

        return image
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                settings: settings,
                reminderService: reminderService,
                networkMonitor: networkMonitor,
                optimizerService: optimizerService,
                agentService: agentService,
                remindersSyncService: remindersSyncService
            )
        } label: {
            Image(nsImage: menuBarIconWithBadge(count: badgeCount))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(reminderService)
                .environment(optimizerService)
                .environment(agentService)
                .environment(remindersSyncService)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
