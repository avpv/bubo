import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var alertWindow: NSWindow?
    private var alertObserver: Any?

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

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = alertObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func dismissAlert() {
        alertWindow?.close()
        alertWindow = nil
    }

    private func showAlert(event: CalendarEvent, minutesBefore: Int) {
        alertWindow?.close()

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

        let window = NSWindow(
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

        NSApplication.shared.activate(ignoringOtherApps: true)
        alertWindow = window

        // Auto-dismiss after 60 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.dismissAlert()
        }

        NSSound.beep()
    }
}

extension Notification.Name {
    static let snoozeReminder = Notification.Name("snoozeReminder")
}
