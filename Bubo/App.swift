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

    /// Local-only container for Apple Calendar event cache. Stays out of
    /// CloudKit because EventKit already syncs iCloud calendars at the OS
    /// level, and the cache is a per-device scratch pad atomically rebuilt
    /// on every sync. Keeps `@Attribute(.unique)` on `PersistedCachedEvent`
    /// as a last-line dedup defence.
    private let eventCacheContainer: ModelContainer

    /// User-authored event data: manually created local events, excluded
    /// recurrence occurrences, and per-event reminder overrides. Opts into
    /// CloudKit when the user enables sync. Models here deliberately avoid
    /// `@Attribute(.unique)` (CloudKit rejects it) and carry `updatedAt`
    /// for last-writer-wins reconciliation on import.
    private let userEventsContainer: ModelContainer

    /// Backlog tasks container — opts into CloudKit on the same flag.
    private let backlogContainer: ModelContainer

    /// UserDefaults flag controlling whether CloudKit-backed SwiftData
    /// stores (user events + backlog) opt into sync. Defaults to `false` —
    /// users flip it from Settings. The flag is read at launch; switching
    /// it requires a restart because `ModelContainer` is built once per
    /// process.
    static let cloudSyncPreferenceKey = "BuboCloudSyncEnabled"

    /// URLs of the dedicated stores. Keeping each model family in its own
    /// file lets us mix local and CloudKit-backed configurations in one
    /// process without the "one unique attribute poisons the whole
    /// container" problem.
    static let eventCacheStoreURL: URL = URL.applicationSupportDirectory
        .appending(path: "EventCache.store")
    static let userEventsStoreURL: URL = URL.applicationSupportDirectory
        .appending(path: "UserEvents.store")
    static let backlogStoreURL: URL = URL.applicationSupportDirectory
        .appending(path: "Backlog.store")

    private static func makeEventCacheContainer() throws -> ModelContainer {
        let schema = Schema([PersistedCachedEvent.self])
        let config = ModelConfiguration(
            schema: schema,
            url: eventCacheStoreURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func makeUserEventsContainer(cloudEnabled: Bool) throws -> ModelContainer {
        let schema = Schema([
            PersistedLocalEvent.self,
            PersistedExcludedOccurrence.self,
            PersistedReminderOverride.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            url: userEventsStoreURL,
            cloudKitDatabase: cloudEnabled ? .automatic : .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func makeBacklogContainer(cloudEnabled: Bool) throws -> ModelContainer {
        let schema = Schema([PersistedBacklogTask.self])
        let config = ModelConfiguration(
            schema: schema,
            url: backlogStoreURL,
            cloudKitDatabase: cloudEnabled ? .automatic : .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Build a container, retrying once with CloudKit disabled if the
    /// mirrored build fails, and falling back to a clean local store if
    /// the file itself is corrupt. Centralising this keeps the three
    /// container init sites from repeating the same recovery dance.
    private static func resilientContainer(
        storeURL: URL,
        cloudEnabled: Bool,
        build: (Bool) throws -> ModelContainer
    ) -> ModelContainer {
        do {
            return try build(cloudEnabled)
        } catch {
            if cloudEnabled, let retry = try? build(false) {
                return retry
            }
            try? FileManager.default.removeItem(at: storeURL)
            for suffix in ["-wal", "-shm"] {
                let sidecar = storeURL.deletingPathExtension()
                    .appendingPathExtension(storeURL.pathExtension + suffix)
                try? FileManager.default.removeItem(at: sidecar)
            }
            do {
                return try build(false)
            } catch {
                fatalError("Failed to create ModelContainer at \(storeURL.lastPathComponent) after reset: \(error)")
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let cloudPreference = defaults.object(forKey: Self.cloudSyncPreferenceKey) as? Bool ?? false

        self.eventCacheContainer = Self.resilientContainer(
            storeURL: Self.eventCacheStoreURL,
            cloudEnabled: false
        ) { _ in try Self.makeEventCacheContainer() }

        self.userEventsContainer = Self.resilientContainer(
            storeURL: Self.userEventsStoreURL,
            cloudEnabled: cloudPreference
        ) { try Self.makeUserEventsContainer(cloudEnabled: $0) }

        self.backlogContainer = Self.resilientContainer(
            storeURL: Self.backlogStoreURL,
            cloudEnabled: cloudPreference
        ) { try Self.makeBacklogContainer(cloudEnabled: $0) }

        // Surface CloudKit sync state to the UI and pull the settings /
        // learning-data side of iCloud in one go. Events from the shared
        // `NSPersistentCloudKitContainer` are posted globally, so we don't
        // need to hand container references in — the monitor just needs
        // to be alive before the first import/export fires.
        if cloudPreference {
            CloudKitSyncMonitor.shared.start(
                containerIdentifier: "iCloud.\(Bundle.main.bundleIdentifier ?? "")"
            )
            CloudSyncService.shared.performInitialSync()
        }

        let s = ReminderSettings.load()
        _settings = State(wrappedValue: s)
        _reminderService = State(wrappedValue: ReminderService(
            settings: s,
            eventCacheContainer: eventCacheContainer,
            userEventsContainer: userEventsContainer
        ))

        let optimizer = OptimizerService()
        let backlogService = BacklogService(modelContainer: backlogContainer)
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
