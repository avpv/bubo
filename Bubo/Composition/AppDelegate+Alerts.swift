import AppKit
import SwiftUI

// MARK: - Full-Screen Alert
//
// Modal alert window for upcoming events, plus the small queue
// helpers (enqueue / tearDown / showNext).
// Extracted from AppDelegate.swift.

extension AppDelegate {

    func dismissAlert() {
        tearDownAlertWindow()
        showNextPendingAlert()
    }

    func enqueueAlert(event: CalendarEvent, minutesBefore: Int, nextEvent: CalendarEvent? = nil) {
        if alertWindow != nil {
            pendingAlerts.append((event: event, minutesBefore: minutesBefore, nextEvent: nextEvent))
        } else {
            showAlert(event: event, minutesBefore: minutesBefore, nextEvent: nextEvent)
        }
    }

    func tearDownAlertWindow() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        if let monitor = alertKeyMonitor {
            NSEvent.removeMonitor(monitor)
            alertKeyMonitor = nil
        }
        if let monitor = alertGlobalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            alertGlobalKeyMonitor = nil
        }
        guard let window = alertWindow else { return }
        alertWindow = nil
        window.orderOut(nil)
        window.close()
    }

    func showNextPendingAlert() {
        while let next = pendingAlerts.first {
            pendingAlerts.removeFirst()
            // Skip events that have already started — no point showing
            // an alert that would auto-dismiss immediately.
            if next.event.startDate > Date() {
                showAlert(event: next.event, minutesBefore: next.minutesBefore, nextEvent: next.nextEvent)
                return
            }
        }
    }


    // MARK: - Full-Screen Alert

    func showAlert(event: CalendarEvent, minutesBefore: Int, nextEvent: CalendarEvent? = nil) {
        tearDownAlertWindow()

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
            },
            nextEvent: nextEvent,
            onJoin: { [weak self] url in
                // J1: open the meeting and hand off to the ribbon so
                // the user keeps a tiny «I joined this; here's the
                // countdown» surface instead of the alert vanishing
                // outright. Re-alert from the ribbon brings the full
                // alert back if Zoom hasn't actually opened.
                NSWorkspace.shared.open(url)
                MainActor.assumeIsolated {
                    self?.dismissAlert()
                    self?.presentJoinRibbon(for: event)
                }
            }
        )
        .environment(\.activeSkin, activeSkin)
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)

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
        // Show the alert on every Space, including the dedicated Space that
        // macOS creates for full-screen apps (Zoom, Google Meet, Teams, etc.).
        // `.canJoinAllSpaces` alone is not enough: when the active Space is a
        // full-screen app's Space, the window must also be `.fullScreenAuxiliary`
        // to be allowed to render over it, and `.stationary` so it stays put as
        // the user switches Spaces instead of being pulled back to the Space it
        // was created on. Without `.stationary` the alert silently fails to
        // appear when another meeting is currently running in full-screen.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostingView)

        // Force activation so the alert window receives keyboard focus,
        // even when a full-screen app (Zoom, Teams) is in the foreground.
        NSApp.activate()
        alertWindow = window

        // Retry activation after a short delay – macOS may not immediately
        // grant focus when switching away from a full-screen Space.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard let self, let w = self.alertWindow else { return }
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            if let hv = w.contentView {
                w.makeFirstResponder(hv)
            }
        }

        // Install a local keyDown monitor for Esc/Return.
        // SwiftUI's .onKeyPress / .keyboardShortcut inside an NSHostingView hosted
        // by a borderless screenSaver-level window does not consistently receive
        // key events, so we handle them at the AppKit level here.
        let meetingURL = event.meetingLink
        alertKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            // Only intercept when our alert is showing (no strict window
            // identity check – the window ref inside nsEvent can be nil
            // for borderless/screenSaver-level windows).
            guard self?.alertWindow != nil else { return nsEvent }
            switch nsEvent.keyCode {
            case 53: // Escape
                MainActor.assumeIsolated {
                    self?.dismissAlert()
                }
                return nil
            case 36, 76: // Return, Enter (numpad)
                MainActor.assumeIsolated {
                    if let url = meetingURL {
                        // J1: route through the same Join handler as the
                        // button so the keyboard and pointer paths produce
                        // the same follow-up ribbon.
                        NSWorkspace.shared.open(url)
                        self?.dismissAlert()
                        self?.presentJoinRibbon(for: event)
                    } else {
                        self?.dismissAlert()
                    }
                }
                return nil
            default:
                return nsEvent
            }
        }

        // Global monitor as fallback – catches key events even when the app
        // is not the active application (e.g. a full-screen meeting holds focus).
        // Note: requires Accessibility permission (System Settings → Privacy
        // & Security → Accessibility). Without it the monitor silently won't
        // be created and only the local monitor + activation retry remain.
        alertGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            guard self?.alertWindow != nil else { return }
            switch nsEvent.keyCode {
            case 53: // Escape
                MainActor.assumeIsolated {
                    self?.dismissAlert()
                }
            case 36, 76: // Return, Enter (numpad)
                MainActor.assumeIsolated {
                    if let url = meetingURL {
                        NSWorkspace.shared.open(url)
                        self?.dismissAlert()
                        self?.presentJoinRibbon(for: event)
                    } else {
                        self?.dismissAlert()
                    }
                }
            default:
                break
            }
        }

        // Auto-dismiss when the event starts (countdown reaches 0)
        autoDismissTask?.cancel()
        let secondsUntilStart = max(event.startDate.timeIntervalSinceNow, 0)
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(secondsUntilStart))
            guard !Task.isCancelled else { return }
            self?.dismissAlert()
        }
    }
}
