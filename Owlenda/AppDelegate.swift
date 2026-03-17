import AppKit
import SwiftUI

private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var alertWindow: NSWindow?
    private var alertObserver: Any?
    private var autoDismissTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        alertObserver = NotificationCenter.default.addObserver(
            forName: .showFullScreenAlert,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? CalendarEvent,
                  let minutes = notification.userInfo?["minutesBefore"] as? Int else { return }
            self?.showAlert(event: event, minutesBefore: minutes)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = alertObserver {
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

    private func showAlert(event: CalendarEvent, minutesBefore: Int) {
        dismissAlert()

        guard let screen = NSScreen.main else { return }

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

        let hostingView = NSHostingView(rootView: alertView)

        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate()
        alertWindow = window

        // Auto-dismiss after 60 seconds
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.dismissAlert()
        }
    }
}

extension Notification.Name {
    static let snoozeReminder = Notification.Name("snoozeReminder")
}
