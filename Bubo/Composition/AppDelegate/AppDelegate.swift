import AppKit
import SwiftUI
import os
import BuboDomain

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "App/Lifecycle")

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Let SwiftUI handle the event first via the responder chain.
        // Without this override the borderless window beeps on every key press
        // and .keyboardShortcut / .onKeyPress never fire.
        if let responder = firstResponder, responder !== self {
            responder.keyDown(with: event)
        }
    }
}

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var alertWindow: NSWindow?
    var alertObserver: Any?
    var alertKeyMonitor: Any?
    var alertGlobalKeyMonitor: Any?
    var autoDismissTask: Task<Void, Never>?
    var pendingAlerts: [(event: CalendarEvent, minutesBefore: Int, nextEvent: CalendarEvent?)] = []
    var pinnedTimerWindow: NSPanel?
    var pinObserver: Any?
    var unpinObserver: Any?

    // J5: Global quick-capture
    var quickCaptureWindow: NSPanel?
    var quickCaptureLocalMonitor: Any?
    var quickCaptureGlobalMonitor: Any?

    // J1: Post-Join ribbon
    var joinRibbonWindow: NSPanel?
    var joinRibbonAutoDismissTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        logger.info("app_did_finish_launching version=\(version, privacy: .public) build=\(build, privacy: .public)")

        // Register for remote notifications so `NSPersistentCloudKitContainer`
        // receives the silent pushes it uses to pull remote changes live.
        // Without this, backlog sync only catches up on the next foreground
        // launch. No-op on machines without the APS entitlement — the
        // registration call is cheap and CloudKit still works in pull mode.
        NSApp.registerForRemoteNotifications()

        alertObserver = NotificationCenter.default.addObserver(
            forName: .showFullScreenAlert,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? CalendarEvent,
                  let minutes = notification.userInfo?["minutesBefore"] as? Int else { return }
            // J4: optional «next back-to-back» event — present when the
            // scheduler found one within ~10 min after this one ends.
            // Forwarded into the alert so it can render a quiet hint.
            let nextEvent = notification.userInfo?["nextEvent"] as? CalendarEvent
            MainActor.assumeIsolated {
                self?.enqueueAlert(event: event, minutesBefore: minutes, nextEvent: nextEvent)
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

        // J5: install the global quick-capture hotkey monitors.
        // Idempotent — calling more than once is a no-op because
        // `installQuickCaptureHotkey` early-exits if the monitors are
        // already attached.
        installQuickCaptureHotkey()

        // Workaround for SwiftUI Settings window leaving the app in the Dock.
        //
        // Important constraints:
        // 1. Never call NSApp.hide(nil) — it corrupts MenuBarExtra state,
        //    preventing the popover from reopening and causing the status-bar
        //    icon to disappear on click.
        // 2. Only respond to real, user-visible Settings windows — ignore
        //    internal SwiftUI scaffold windows that may briefly exist during
        //    scene initialization (they can match the "Settings" identifier
        //    but were never shown on screen).
        // 3. Only reset to .accessory when the policy was actually changed
        //    to .regular (by opening Settings). Calling setActivationPolicy
        //    while already .accessory disrupts MenuBarExtra's internal state
        //    and causes the status-bar icon to disappear on click.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  window.isVisible,
                  window.title.contains("Settings") || window.identifier?.rawValue.contains("Settings") == true
            else { return }
            DispatchQueue.main.async {
                guard NSApp.activationPolicy() == .regular else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("app_will_terminate")
        if let observer = alertObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = pinObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = unpinObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = quickCaptureLocalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = quickCaptureGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSPanel {
            if window === pinnedTimerWindow {
                pinnedTimerWindow = nil
            } else if window === quickCaptureWindow {
                quickCaptureWindow = nil
            } else if window === joinRibbonWindow {
                joinRibbonAutoDismissTask?.cancel()
                joinRibbonAutoDismissTask = nil
                joinRibbonWindow = nil
            }
        }
    }
}

extension Notification.Name {
    static let snoozeReminder = Notification.Name("snoozeReminder")
    static let pinTimerWindow = Notification.Name("pinTimerWindow")
    static let unpinTimerWindow = Notification.Name("unpinTimerWindow")
    /// J5: posted by AppDelegate after the user commits text in the
    /// global quick-capture overlay. `userInfo["text"]` holds the
    /// trimmed task title. Listened for in `MenuBarView`, which calls
    /// `BacklogService.addTask(...)` and surfaces an undo toast.
    static let didCaptureBacklogTask = Notification.Name("didCaptureBacklogTask")
    /// Posted on `⇧↩` from quick-capture: the user wants the compact
    /// `NewTaskView` instead of a one-shot add. `userInfo["text"]` carries
    /// the typed prefill (possibly empty). `MenuBarView` reacts by
    /// pushing `.newTask(...)` onto the popover stack; the prefill is
    /// also buffered in `QuickCaptureBridge.shared` for the case where
    /// the popover wasn't open at the moment the notification fired.
    static let didCaptureBacklogTaskWithDetails = Notification.Name("didCaptureBacklogTaskWithDetails")
}
