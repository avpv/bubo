import AppKit
import SwiftUI
import BuboDomain

// MARK: - Pinned Timer Window
//
// Floating panel that pins a running timer / pomodoro on top.
// Extracted from AppDelegate.swift.

extension AppDelegate {

    // MARK: - Pinned Timer Window

    func dismissPinnedTimer() {
        guard let window = pinnedTimerWindow else { return }
        pinnedTimerWindow = nil
        window.orderOut(nil)
        window.close()
    }

    func showPinnedTimer(event: CalendarEvent) {
        dismissPinnedTimer()

        let settings = ReminderSettings.load()
        let activeSkin = settings.selectedSkin
        let timerView = TimerScreenView(
            event: event,
            onBack: { [weak self] in
                self?.dismissPinnedTimer()
            },
            isPinned: true,
            customPhotoPath: settings.customBackgroundPhotoPath,
            customPhotoOpacity: settings.customBackgroundPhotoOpacity,
            customPhotoBlur: settings.customBackgroundPhotoBlur
        )

        // Match the menu-bar popover root: skin environment + tint +
        // typography, so the pinned timer reads as the same product
        // rather than an un-skinned floating window. PRINCIPLES §8 / §10.
        let hostingView = NSHostingView(rootView: timerView
            .environment(\.activeSkin, activeSkin)
            .skinTinted(activeSkin)
            .skinTypography(activeSkin)
        )

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: DS.Popover.width, height: DS.Popover.timerHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = visualEffect
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        // Position near top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - DS.Popover.width - 20
            let y = screenFrame.maxY - DS.Popover.timerHeight - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        pinnedTimerWindow = panel
    }
}
