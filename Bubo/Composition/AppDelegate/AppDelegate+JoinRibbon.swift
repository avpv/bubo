import AppKit
import SwiftUI
import BuboDomain

// MARK: - Post-Join Ribbon (J1)
//
// Transient ribbon that surfaces after a meeting auto-joins.
// Extracted from AppDelegate.swift.

extension AppDelegate {

    // MARK: - Post-Join Ribbon (J1)
    //
    // After the user taps «Join …» (or hits Return), the full-screen
    // alert tears down and a slim floating ribbon takes over a small
    // band near the top of the screen. The ribbon carries a live
    // countdown to start, plus one explicit «Re-alert» button that
    // brings the full-screen surface back if the meeting app didn't
    // open as expected. Auto-dismisses at `event.startDate`.

    func presentJoinRibbon(for event: CalendarEvent) {
        // Replace any prior ribbon — if a second alert fires while the
        // first ribbon is up, we want only the latest event reflected.
        dismissJoinRibbon()

        guard let screen = NSScreen.main else { return }
        let settings = ReminderSettings.load()
        let activeSkin = settings.selectedSkin

        let ribbon = JoinRibbonView(
            event: event,
            onReAlert: { [weak self] in
                MainActor.assumeIsolated {
                    self?.dismissJoinRibbon()
                    // Re-show the same alert; minutes-before is the
                    // remaining-to-start in minutes (rounded down) so
                    // the urgency colour stays accurate.
                    let remaining = max(0, Int(event.startDate.timeIntervalSinceNow / 60))
                    self?.enqueueAlert(event: event, minutesBefore: remaining, nextEvent: nil)
                }
            },
            onDismiss: { [weak self] in
                MainActor.assumeIsolated { self?.dismissJoinRibbon() }
            }
        )
        .environment(\.activeSkin, activeSkin)
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)

        let hosted = NSHostingView(rootView: ribbon)
        hosted.translatesAutoresizingMaskIntoConstraints = false

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hosted.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = visualEffect
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self

        // Position: horizontally centred near the top of the screen
        // (≈12pt below the menu bar), so the ribbon reads as a
        // status surface, not a floating popover blocking content.
        let frame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = frame.midX - panelSize.width / 2
        let y = frame.maxY - panelSize.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.orderFront(nil)
        joinRibbonWindow = panel
        joinRibbonEvent = event

        // Auto-dismiss at event start. Cancelled if the user hits
        // Re-alert (which tears the ribbon down explicitly first).
        joinRibbonAutoDismissTask?.cancel()
        let seconds = max(event.startDate.timeIntervalSinceNow, 0)
        joinRibbonAutoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismissJoinRibbon()
        }
    }

    func dismissJoinRibbon() {
        joinRibbonAutoDismissTask?.cancel()
        joinRibbonAutoDismissTask = nil
        joinRibbonEvent = nil
        guard let panel = joinRibbonWindow else { return }
        joinRibbonWindow = nil
        panel.orderOut(nil)
        panel.close()
    }

}
