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

    private var menuBarIcon: NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width

            ctx.setFillColor(NSColor.black.cgColor)

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

            return true
        }
        image.isTemplate = true
        return image
    }

    private var badgeCount: Int {
        reminderService.badgeCount
    }

    private func menuBarIconWithBadge(count: Int) -> NSImage {
        let icon = menuBarIcon
        guard count > 0 else { return icon }

        let badgeText = "\(count)" as NSString
        let fontSize: CGFloat = 9
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = badgeText.size(withAttributes: attrs)
        let badgeHeight: CGFloat = 12
        let badgeWidth = max(badgeHeight, textSize.width + 6)

        let totalWidth = icon.size.width + 2 + badgeWidth
        let totalHeight = max(icon.size.height, badgeHeight)

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            // Draw original icon aligned left-center
            let iconY = (rect.height - icon.size.height) / 2
            icon.draw(in: NSRect(x: 0, y: iconY, width: icon.size.width, height: icon.size.height))

            // Draw badge pill to the right
            let badgeX = icon.size.width + 2
            let badgeY = (rect.height - badgeHeight) / 2
            let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
            let path = NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2)
            NSColor.black.setFill()
            path.fill()

            // Draw text centered in badge
            let textX = badgeX + (badgeWidth - textSize.width) / 2
            let textY = badgeY + (badgeHeight - textSize.height) / 2
            badgeText.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            return true
        }
        image.isTemplate = true
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
