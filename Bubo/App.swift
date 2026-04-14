import SwiftUI
import SwiftData

private class MenuBarIconCache {
    var count: Int = -1
    var skinID: String = ""
    var image: NSImage?
}
private let sharedIconCache = MenuBarIconCache()

struct AppDependencies {
    let settings: ReminderSettings
    let reminderService: ReminderService
    let optimizerService: OptimizerService
    let agentService: AgentService
    let remindersSyncService: RemindersSyncService
}

@main
struct BuboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var networkMonitor = NetworkMonitor()
    @State private var dependencies: AppDependencies?

    private func loadDependencies() async {
        // Run heavy container creation off main thread
        let (localContainer, backlogContainer) = await Task.detached(priority: .userInitiated) {
            // Pull any existing iCloud data before services load from UserDefaults.
            CloudSyncService.shared.performInitialSync()

            // Local-only container for calendar events (not synced to iCloud).
            let container: ModelContainer
            do {
                container = try ModelContainer(for:
                    PersistedLocalEvent.self,
                    PersistedCachedEvent.self,
                    PersistedExcludedOccurrence.self,
                    PersistedReminderOverride.self
                )
            } catch {
                let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
                try? FileManager.default.removeItem(at: storeURL)
                for suffix in ["-wal", "-shm"] {
                    let sidecar = storeURL.deletingPathExtension().appendingPathExtension(storeURL.pathExtension + suffix)
                    try? FileManager.default.removeItem(at: sidecar)
                }
                do {
                    container = try ModelContainer(for:
                        PersistedLocalEvent.self,
                        PersistedCachedEvent.self,
                        PersistedExcludedOccurrence.self,
                        PersistedReminderOverride.self
                    )
                } catch {
                    fatalError("Failed to create ModelContainer after reset: \(error)")
                }
            }

            // CloudKit-synced container for backlog tasks.
            let bContainer: ModelContainer
            do {
                let cloudConfig = ModelConfiguration(
                    "BacklogCloud",
                    schema: Schema([PersistedBacklogTask.self]),
                    cloudKitDatabase: .automatic
                )
                bContainer = try ModelContainer(
                    for: PersistedBacklogTask.self,
                    configurations: cloudConfig
                )
            } catch {
                do {
                    let localConfig = ModelConfiguration(
                        "BacklogLocal",
                        schema: Schema([PersistedBacklogTask.self])
                    )
                    bContainer = try ModelContainer(
                        for: PersistedBacklogTask.self,
                        configurations: localConfig
                    )
                } catch {
                    fatalError("Failed to create backlog ModelContainer: \(error)")
                }
            }
            return (container, bContainer)
        }.value

        let s = ReminderSettings.load()
        let rService = ReminderService(settings: s, modelContainer: localContainer)

        let optimizer = OptimizerService()
        let backlog = BacklogService(modelContainer: backlogContainer)
        optimizer.backlogService = backlog
        optimizer.energyCheckInService = EnergyCheckInService()

        let syncService = RemindersSyncService(settings: s, backlogService: backlog)
        let agent = AgentService()

        self.dependencies = AppDependencies(
            settings: s,
            reminderService: rService,
            optimizerService: optimizer,
            agentService: agent,
            remindersSyncService: syncService
        )
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

    private func useSkinIcon(settings: ReminderSettings) -> Bool {
        let skinID = settings.selectedSkinID
        return skinID != "system" && skinID != "classic"
    }

    private func resolvedIconColor(settings: ReminderSettings, isDark: Bool) -> CGColor {
        let base = NSColor(settings.selectedSkin.accentColor)
            .usingColorSpace(.sRGB) ?? NSColor(settings.selectedSkin.accentColor)

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Relative luminance approximation (rec. 709)
        let r = base.redComponent, g = base.greenComponent, bl = base.blueComponent
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * bl

        if isDark {
            // Dark menu bar → icon needs to be bright enough (lum > 0.25)
            if lum < 0.25 {
                let adjusted = NSColor(hue: h, saturation: s * 0.8, brightness: max(b, 0.65), alpha: a)
                return adjusted.cgColor
            }
        } else {
            // Light menu bar → icon needs to be dark enough (lum < 0.7)
            if lum > 0.7 {
                let adjusted = NSColor(hue: h, saturation: max(s, 0.5), brightness: min(b, 0.55), alpha: a)
                return adjusted.cgColor
            }
        }
        return base.cgColor
    }

    private func menuBarIcon(settings: ReminderSettings) -> NSImage {
        let currentSkinID = settings.selectedSkinID
        if sharedIconCache.count == 0, sharedIconCache.skinID == currentSkinID, let img = sharedIconCache.image {
            return img
        }

        let size = NSSize(width: 18, height: 18)
        let useCustom = useSkinIcon(settings: settings)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color: CGColor = useCustom
                ? self.resolvedIconColor(settings: settings, isDark: isDark)
                : (isDark ? NSColor.white.cgColor : NSColor.black.cgColor)
            self.drawOwl(in: ctx, size: rect.width, color: color)
            return true
        }
        image.isTemplate = !useSkinIcon(settings: settings)

        sharedIconCache.count = 0
        sharedIconCache.skinID = currentSkinID
        sharedIconCache.image = image

        return image
    }

    private func menuBarIconWithBadge(count: Int, settings: ReminderSettings) -> NSImage {
        guard count > 0 else { return menuBarIcon(settings: settings) }

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

        // Badge at bottom-right, overlapping the icon
        let overlapX: CGFloat = badgeWidth * 0.3
        let overlapY: CGFloat = badgeDiameter * 0.35
        let totalWidth = iconSize + badgeWidth - overlapX
        let bottomOverflow = max(0, overlapY - 1)
        let totalHeight = iconSize + bottomOverflow

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Determine icon color with contrast safety
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let iconColor: CGColor = self.useSkinIcon(settings: settings)
                ? self.resolvedIconColor(settings: settings, isDark: isDark)
                : (isDark ? NSColor.white.cgColor : NSColor.black.cgColor)

            // Draw owl icon shifted up to make room for badge overflow at the bottom
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bottomOverflow + 2)
            self.drawOwl(in: ctx, size: iconSize, color: iconColor)
            ctx.restoreGState()

            // Cut out a circular area from the owl where the badge will sit
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

            // Badge color: always system red per Apple HIG
            let badgeColor = NSColor.systemRed

            // Badge shadow for depth
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeDiameter / 2, yRadius: badgeDiameter / 2)
            badgeColor.setFill()
            badgePath.fill()
            ctx.restoreGState()

            // Badge fill on top (crisp, no shadow)
            badgeColor.setFill()
            badgePath.fill()

            // Subtle inner highlight at top of badge
            let highlightRect = NSRect(x: badgeX + 1.5, y: badgeY + badgeDiameter * 0.5, width: badgeWidth - 3, height: badgeDiameter * 0.4)
            let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 3, yRadius: 3)
            NSColor.white.withAlphaComponent(0.15).setFill()
            highlightPath.fill()

            // Draw count text centered in badge
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
            if let deps = dependencies {
                MenuBarView(
                    settings: deps.settings,
                    reminderService: deps.reminderService,
                    networkMonitor: networkMonitor,
                    optimizerService: deps.optimizerService,
                    agentService: deps.agentService,
                    remindersSyncService: deps.remindersSyncService
                )
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Bubo...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 32)
                .task {
                    guard dependencies == nil else { return }
                    await loadDependencies()
                }
            }
        } label: {
            if let deps = dependencies {
                Image(nsImage: menuBarIconWithBadge(count: deps.reminderService.badgeCount, settings: deps.settings))
            } else {
                Image(systemName: "hourglass")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let deps = dependencies {
                SettingsView()
                    .environment(deps.settings)
                    .environment(deps.reminderService)
                    .environment(deps.optimizerService)
                    .environment(deps.agentService)
                    .environment(deps.remindersSyncService)
            } else {
                VStack {
                    ProgressView().padding()
                    Text("Loading Bubo Environments...")
                }
                .frame(width: 400, height: 300)
                .task {
                    guard dependencies == nil else { return }
                    await loadDependencies()
                }
            }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
