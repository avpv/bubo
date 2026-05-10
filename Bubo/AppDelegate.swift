import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "App/Lifecycle")

private class KeyableWindow: NSWindow {
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

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var alertWindow: NSWindow?
    private var alertObserver: Any?
    private var alertKeyMonitor: Any?
    private var alertGlobalKeyMonitor: Any?
    private var autoDismissTask: Task<Void, Never>?
    private var pendingAlerts: [(event: CalendarEvent, minutesBefore: Int, nextEvent: CalendarEvent?)] = []
    private var pinnedTimerWindow: NSPanel?
    private var pinObserver: Any?
    private var unpinObserver: Any?

    // J5: Global quick-capture
    private var quickCaptureWindow: NSPanel?
    private var quickCaptureLocalMonitor: Any?
    private var quickCaptureGlobalMonitor: Any?

    // J1: Post-Join ribbon
    private var joinRibbonWindow: NSPanel?
    private var joinRibbonAutoDismissTask: Task<Void, Never>?

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

    func dismissAlert() {
        tearDownAlertWindow()
        showNextPendingAlert()
    }

    private func enqueueAlert(event: CalendarEvent, minutesBefore: Int, nextEvent: CalendarEvent? = nil) {
        if alertWindow != nil {
            pendingAlerts.append((event: event, minutesBefore: minutesBefore, nextEvent: nextEvent))
        } else {
            showAlert(event: event, minutesBefore: minutesBefore, nextEvent: nextEvent)
        }
    }

    private func tearDownAlertWindow() {
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

    private func showNextPendingAlert() {
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

    // MARK: - Quick Capture (J5)
    //
    // Global hotkey (default `⌃⇧⌘Space`) summons a small floating panel
    // with a single text field — "Add to backlog…". Return commits the
    // task; Esc cancels. AppDelegate manages the panel + the hotkey
    // monitors, but never touches `BacklogService` directly: the captured
    // text is published through `.didCaptureBacklogTask` and the
    // menu-bar listener inserts it via the service. Keeps AppDelegate
    // free of service dependencies — same pattern the alert / pin
    // observers use.
    //
    // The hotkey is intentionally an OBSERVE-only monitor (we don't
    // intercept the keystroke from the foreground app). The chord
    // chosen — `⌃⇧⌘` + Space — collides with nothing in stock macOS,
    // so observation is enough in practice. Upgrade path: Carbon
    // RegisterEventHotKey for true interception when the chord is
    // user-customisable.

    /// Key code for `Space` on macOS keyboards. Stable across layouts.
    private static let spaceKeyCode: UInt16 = 49

    /// Modifier mask we listen for. Equality (not subset) so adding
    /// extra modifiers like `.option` doesn't trigger.
    private static let quickCaptureModifiers: NSEvent.ModifierFlags = [.control, .shift, .command]

    private func installQuickCaptureHotkey() {
        // Idempotent: if either monitor is already alive, treat the
        // install as already done. Avoids double-firing when an SDK
        // path calls back into `applicationDidFinishLaunching`.
        guard quickCaptureLocalMonitor == nil && quickCaptureGlobalMonitor == nil else { return }

        // Local monitor — fires only while Bubo is the active app
        // (popover open with focus, settings window visible). Returns
        // the event so it propagates to focus subviews unless we
        // claimed the chord, in which case we swallow it.
        quickCaptureLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == Self.spaceKeyCode else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == Self.quickCaptureModifiers else { return event }
            MainActor.assumeIsolated { self.toggleQuickCapture() }
            return nil
        }

        // Global monitor — fires while another app is in the
        // foreground. Cannot consume the event (system limitation), so
        // we pick a chord nothing else uses. Requires Accessibility
        // permission to receive global key events; without it the
        // monitor is silently never installed by the OS, and only the
        // local monitor is left.
        quickCaptureGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            guard event.keyCode == Self.spaceKeyCode else { return }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == Self.quickCaptureModifiers else { return }
            MainActor.assumeIsolated { self.toggleQuickCapture() }
        }
    }

    /// If the panel is open, dismiss it; otherwise show it. Reused by
    /// both monitors so a second hotkey press cancels an open prompt.
    private func toggleQuickCapture() {
        if quickCaptureWindow != nil {
            dismissQuickCapture()
        } else {
            presentQuickCapture()
        }
    }

    private func presentQuickCapture() {
        guard quickCaptureWindow == nil else { return }
        guard let screen = NSScreen.main else { return }

        // Compose the SwiftUI overlay. Submit posts the captured text
        // as a notification — the menu-bar layer turns it into a
        // BacklogTask. Cancel just tears down the panel.
        let view = QuickCaptureView(
            onSubmit: { [weak self] text in
                MainActor.assumeIsolated {
                    NotificationCenter.default.post(
                        name: .didCaptureBacklogTask,
                        object: nil,
                        userInfo: ["text": text]
                    )
                    self?.dismissQuickCapture()
                }
            },
            onSubmitWithDetails: { [weak self] text in
                MainActor.assumeIsolated {
                    // Two paths here, run in parallel so the form lands
                    // whether or not the popover is currently open:
                    //  - Notification: the fast path. `MenuBarView` is in
                    //    the view tree if the popover is open and routes
                    //    straight to `.newTask(...)`.
                    //  - `QuickCaptureBridge.shared`: the slow path.
                    //    Survives until the next time `MenuBarView`
                    //    appears, so a closed popover doesn't drop the
                    //    prefill on the floor.
                    QuickCaptureBridge.shared.setPending(text)
                    NotificationCenter.default.post(
                        name: .didCaptureBacklogTaskWithDetails,
                        object: nil,
                        userInfo: ["text": text]
                    )
                    self?.dismissQuickCapture()
                    self?.tryOpenMenuBarPopover()
                }
            },
            onCancel: { [weak self] in
                MainActor.assumeIsolated { self?.dismissQuickCapture() }
            }
        )
        // Tint the overlay with the user's current skin so it visually
        // matches the rest of the app even though it lives in its own
        // window. `ReminderSettings.load()` is the same source the
        // full-screen alert uses for its skin look-up.
        let settings = ReminderSettings.load()
        let activeSkin = settings.selectedSkin
        let hosted = NSHostingView(rootView: view
            .environment(\.activeSkin, activeSkin)
            .skinTinted(activeSkin)
            // PRINCIPLES §8 — the menu-bar popover applies
            // `.skinTypography` at its root so every descendant
            // `Text` inherits SF Rounded + skin body weight. Standalone
            // hosting windows (this one, the join ribbon, the fullscreen
            // alert) carried only `.skinTinted`, which set surface
            // colour but left typography on the system default. Three
            // root setups now agree.
            .skinTypography(activeSkin)
        )
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

        // Sized once to fit the SwiftUI surface; the SwiftUI view
        // declares the canonical width (480pt) and asks AppKit to
        // size to its intrinsic content. Height is approximate; the
        // hosting view auto-resizes once layout runs.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
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
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self

        // Center horizontally, bias toward the upper third — a Spotlight-
        // shaped position. `visibleFrame` excludes the menu bar so the
        // panel never overlaps it.
        let frame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = frame.midX - panelSize.width / 2
        let y = frame.minY + frame.height * 0.66 - panelSize.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        quickCaptureWindow = panel
    }

    private func dismissQuickCapture() {
        guard let panel = quickCaptureWindow else { return }
        quickCaptureWindow = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// Best-effort attempt to open the `MenuBarExtra` popover so a
    /// `⇧↩` quick-capture pivot can mount `NewTaskView` immediately.
    /// SwiftUI doesn't expose programmatic control over `MenuBarExtra`,
    /// so we fish for its status-item button via `NSStatusBar` and click
    /// it. Failures are silent — the prefill is already buffered in
    /// `QuickCaptureBridge.shared`, so the user just opens the popover
    /// manually next and lands on the form anyway.
    private func tryOpenMenuBarPopover() {
        // `NSStatusBar.system` returns every status item registered
        // by the app, including the one `MenuBarExtra` adds. Clicking
        // its button is the same code path the user takes by hand.
        let bar = NSStatusBar.system
        for item in bar.value(forKey: "items") as? [NSStatusItem] ?? [] {
            guard let button = item.button else { continue }
            // Defer to the next runloop tick — clicking before the
            // quick-capture panel has finished tearing down can leave
            // the popover anchored to the wrong key window.
            DispatchQueue.main.async {
                button.performClick(nil)
            }
            return
        }
    }

    // MARK: - Post-Join Ribbon (J1)
    //
    // After the user taps «Join …» (or hits Return), the full-screen
    // alert tears down and a slim floating ribbon takes over a small
    // band near the top of the screen. The ribbon carries a live
    // countdown to start, plus one explicit «Re-alert» button that
    // brings the full-screen surface back if the meeting app didn't
    // open as expected. Auto-dismisses at `event.startDate`.

    private func presentJoinRibbon(for event: CalendarEvent) {
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

    private func dismissJoinRibbon() {
        joinRibbonAutoDismissTask?.cancel()
        joinRibbonAutoDismissTask = nil
        guard let panel = joinRibbonWindow else { return }
        joinRibbonWindow = nil
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Full-Screen Alert

    private func showAlert(event: CalendarEvent, minutesBefore: Int, nextEvent: CalendarEvent? = nil) {
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
