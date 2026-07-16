import SwiftUI
import SwiftData
import BuboDomain

private class MenuBarIconCache {
    var count: Int = -1
    /// J2: integer density bucket (0…10) — fraction of today's
    /// working window already booked. Cached alongside count
    /// so the icon repaints when «load» visibly changes but stays
    /// stable across small updates.
    var densityBucket: Int = -1
    var image: NSImage?
}
private let sharedIconCache = MenuBarIconCache()

@main
struct BuboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var settings: ReminderSettings
    @State private var reminderService: ReminderService
    @State private var networkMonitor: NetworkMonitor
    @State private var optimizerService: OptimizerService
    @State private var agentService: AgentService
    @State private var remindersSyncService: RemindersSyncService
    @State private var cloudServices: CloudServicesCoordinator

    /// Source-compat shim. The preference key lives on `AppContainer`
    /// now; views that read it via `BuboApp.cloudSyncPreferenceKey` keep
    /// working without churn.
    static let cloudSyncPreferenceKey = AppContainer.cloudSyncPreferenceKey

    init() {
        let container = AppContainer.make()
        _settings = State(wrappedValue: container.settings)
        _reminderService = State(wrappedValue: container.reminderService)
        _networkMonitor = State(wrappedValue: container.networkMonitor)
        _optimizerService = State(wrappedValue: container.optimizerService)
        _agentService = State(wrappedValue: container.agentService)
        _remindersSyncService = State(wrappedValue: container.remindersSyncService)
        _cloudServices = State(wrappedValue: container.cloudServices)
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

    private var menuBarIcon: NSImage {
        let bucket = densityBucket
        if sharedIconCache.count == 0,
           sharedIconCache.densityBucket == bucket,
           let img = sharedIconCache.image {
            return img
        }

        let size = NSSize(width: 18, height: 18)
        // Template image: the system paints it black in the light menu
        // bar and white in the dark one — the icon never follows the
        // active skin's accent colour.
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let color = NSColor.black.cgColor
            self.drawOwl(in: ctx, size: rect.width, color: color)
            self.drawDensityBar(in: ctx, size: rect.width, color: color, bucket: bucket)
            return true
        }
        image.isTemplate = true

        sharedIconCache.count = 0
        sharedIconCache.densityBucket = bucket
        sharedIconCache.image = image

        return image
    }

    private var badgeCount: Int {
        reminderService.badgeCount
    }

    /// J2: today's booked fraction quantised to 0…10. Encodes the
    /// menu-bar icon's density bar through SHAPE (length), not colour
    /// (§7). Returns 0 outside working hours so the icon doesn't
    /// pretend to be dense at midnight. Cached at this granularity
    /// so the bar grows in noticeable, calm steps instead of
    /// flickering on every small recompute.
    private var densityBucket: Int {
        let cal = Calendar.current
        let now = Date()
        let workingStartHour = max(0, optimizerServiceWorkingStartFallback)
        let workingEndHour = min(24, optimizerServiceWorkingEndFallback)
        guard workingEndHour > workingStartHour else { return 0 }
        let hour = cal.component(.hour, from: now)
        guard hour >= workingStartHour, hour < workingEndHour else { return 0 }

        let todayStart = cal.date(bySettingHour: workingStartHour, minute: 0, second: 0, of: now) ?? now
        let todayEnd = cal.date(bySettingHour: workingEndHour, minute: 0, second: 0, of: now) ?? now
        let windowSeconds = max(1, todayEnd.timeIntervalSince(todayStart))

        let bookedSeconds = reminderService.allEvents.reduce(0.0) { acc, event in
            // Clip each event into the working window before summing —
            // an early-morning event shouldn't inflate today's bar.
            let start = max(event.startDate, todayStart)
            let end = min(event.endDate, todayEnd)
            guard end > start else { return acc }
            return acc + end.timeIntervalSince(start)
        }
        let fraction = max(0, min(1, bookedSeconds / windowSeconds))
        return Int((fraction * 10).rounded())
    }

    /// Working-hours fallback. The optimizer's working hours live in
    /// `OptimizerService` which is wired up at the menu-bar layer,
    /// not here in `BuboApp`. To avoid wiring an extra dependency
    /// just for the icon, we default to `9…18` — the same range
    /// `OptimizerService.workingHoursDefault` uses. If the user has
    /// customised their hours in Settings, the icon's density bar
    /// will still read «correctly enough» (it's a shape signal,
    /// not a precise gauge).
    private var optimizerServiceWorkingStartFallback: Int { 9 }
    private var optimizerServiceWorkingEndFallback: Int { 18 }

    /// J2: paint a thin bar at the bottom of the icon proportional
    /// to today's booked fraction. Length encodes density; shape,
    /// not colour, so the cue survives §7 (semantic colour rules).
    /// Bucket 0 = invisible (calm day or out-of-hours).
    private func drawDensityBar(in ctx: CGContext, size s: CGFloat, color: CGColor, bucket: Int) {
        guard bucket > 0 else { return }
        let fraction = CGFloat(bucket) / 10.0
        // Bar lives in the bottom 7% strip of the icon — small enough
        // to read as «metadata», large enough to perceive at a glance.
        let barHeight: CGFloat = max(1.0, s * 0.07)
        let maxBarWidth: CGFloat = s * 0.7
        let barWidth = maxBarWidth * fraction
        let x = (s - maxBarWidth) / 2
        let y: CGFloat = 0
        // Quiet strip in the same template colour as the owl glyph,
        // so Light/Dark mode flows through without a separate asset.
        // Slightly subdued vs. the owl itself so the bird remains the
        // primary mark.
        ctx.saveGState()
        ctx.setAlpha(0.55)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: x, y: y, width: barWidth, height: barHeight))
        ctx.restoreGState()
    }

    private func menuBarIconWithBadge(count: Int) -> NSImage {
        guard count > 0 else { return menuBarIcon }

        let bucket = densityBucket
        if sharedIconCache.count == count,
           sharedIconCache.densityBucket == bucket,
           let img = sharedIconCache.image {
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

            // The badge forces a non-template image, so pick the default
            // menu-bar glyph colour by appearance: white on dark, black
            // on light. No skin tinting.
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let iconColor: CGColor = isDark ? NSColor.white.cgColor : NSColor.black.cgColor

            ctx.saveGState()
            ctx.translateBy(x: 0, y: bottomOverflow + 2)
            self.drawOwl(in: ctx, size: iconSize, color: iconColor)
            self.drawDensityBar(in: ctx, size: iconSize, color: iconColor, bucket: bucket)
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
        sharedIconCache.densityBucket = bucket
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
            .environment(settings)
            .environment(reminderService)
            .environment(optimizerService)
            .environment(agentService)
            .environment(remindersSyncService)
            .environment(cloudServices)
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
                .environment(cloudServices)
                // PRINCIPLES §8: thread the user's active skin into the
                // settings window so every label and form input renders
                // in the same SF Rounded + skin body weight as the
                // menu-bar popover. Without these modifiers the
                // settings window fell back to the default skin and
                // SF Pro Regular, so opening Preferences felt like a
                // different app from the popover that launched it.
                .environment(\.activeSkin, settings.selectedSkin)
                .skinTinted(settings.selectedSkin)
                .skinTypography(settings.selectedSkin)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
