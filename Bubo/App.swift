import SwiftUI

@main
struct BuboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings: ReminderSettings
    @State private var reminderService: ReminderService
    @State private var networkMonitor = NetworkMonitor()

    init() {
        let s = ReminderSettings.load()
        _settings = State(wrappedValue: s)
        _reminderService = State(wrappedValue: ReminderService(settings: s))
    }

    private func drawOwl(in ctx: CGContext, size s: CGFloat, color: CGColor) {
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
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawOwl(in: ctx, size: rect.width, color: NSColor.black.cgColor)
            return true
        }
        image.isTemplate = true
        return image
    }

    private var badgeCount: Int {
        reminderService.badgeCount
    }

    private func menuBarIconWithBadge(count: Int) -> NSImage {
        guard count > 0 else { return menuBarIcon }

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
        let totalHeight = iconSize

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Determine icon color based on current appearance (light/dark menu bar)
            let isDark = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let iconColor = isDark ? NSColor.white.cgColor : NSColor.black.cgColor

            // Draw owl icon shifted up slightly to "open" it from the bottom
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 2)
            self.drawOwl(in: ctx, size: iconSize, color: iconColor)
            ctx.restoreGState()

            // Draw badge at bottom-right, overlapping the icon
            let badgeX = iconSize - overlapX
            let badgeY: CGFloat = -overlapY + 1
            let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeDiameter)

            // Badge shadow for depth
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeDiameter / 2, yRadius: badgeDiameter / 2)
            NSColor.systemBlue.setFill()
            badgePath.fill()
            ctx.restoreGState()

            // Badge fill on top (crisp, no shadow)
            NSColor.systemBlue.setFill()
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
        return image
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                settings: settings,
                reminderService: reminderService,
                networkMonitor: networkMonitor
            )
        } label: {
            Image(nsImage: menuBarIconWithBadge(count: badgeCount))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(reminderService)
        }
    }
}
