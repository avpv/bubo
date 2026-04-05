import AppKit
import SwiftUI

private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var alertWindow: NSWindow?
    private var alertObserver: Any?
    private var autoDismissTask: Task<Void, Never>?
    private var pinnedTimerWindow: NSPanel?
    private var pinObserver: Any?
    private var unpinObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        alertObserver = NotificationCenter.default.addObserver(
            forName: .showFullScreenAlert,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? CalendarEvent,
                  let minutes = notification.userInfo?["minutesBefore"] as? Int else { return }
            MainActor.assumeIsolated {
                self?.showAlert(event: event, minutesBefore: minutes)
            }
        }

        pinObserver = NotificationCenter.default.addObserver(
            forName: .pinTimerWindow,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? CalendarEvent else { return }
            MainActor.assumeIsolated {
                self?.showPinnedTimer(event: event)
            }
        }

        unpinObserver = NotificationCenter.default.addObserver(
            forName: .unpinTimerWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissPinnedTimer()
            }
        }

        // Workaround for SwiftUI Settings window leaving the app in the Dock
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                if window.title.contains("Settings") || window.title.contains("Bubo") || window.identifier?.rawValue.contains("Settings") == true {
                    DispatchQueue.main.async {
                        NSApp.setActivationPolicy(.accessory)
                        if NSApp.isActive {
                            NSApp.hide(nil)
                        }
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = alertObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = pinObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = unpinObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func dismissAlert() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let window = alertWindow else { return }
        alertWindow = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Pinned Timer Window

    func dismissPinnedTimer() {
        guard let window = pinnedTimerWindow else { return }
        pinnedTimerWindow = nil
        window.orderOut(nil)
        window.close()
    }

    private func showPinnedTimer(event: CalendarEvent) {
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

        let hostingView = NSHostingView(rootView: timerView)

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

    // MARK: - Full-Screen Alert

    private func showAlert(event: CalendarEvent, minutesBefore: Int) {
        dismissAlert()

        guard let screen = NSScreen.main else { return }

        let settings = ReminderSettings.load()
        let activeSkin = settings.selectedSkin

        let alertView = FullScreenAlertView(
            event: event,
            minutesBefore: minutesBefore,
            onDismiss: { [weak self] in
                self?.dismissAlert()
            },
            onSnooze: { [weak self] minutes in
                self?.dismissAlert()
                NotificationCenter.default.post(
                    name: .snoozeReminder,
                    object: nil,
                    userInfo: ["event": event, "minutes": minutes]
                )
            }
        )
        .environment(\.activeSkin, activeSkin)
        .skinTinted(activeSkin)

        let hostingView = NSHostingView(rootView: alertView)

        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate()
        alertWindow = window

        // Auto-dismiss when the event starts (countdown reaches 0)
        autoDismissTask?.cancel()
        let secondsUntilStart = max(event.startDate.timeIntervalSinceNow, 0)
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(secondsUntilStart))
            self?.dismissAlert()
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSPanel, window === pinnedTimerWindow {
            pinnedTimerWindow = nil
        }
    }
}

extension Notification.Name {
    static let snoozeReminder = Notification.Name("snoozeReminder")
    static let pinTimerWindow = Notification.Name("pinTimerWindow")
    static let unpinTimerWindow = Notification.Name("unpinTimerWindow")
}
