import AppKit
import SwiftUI
import BuboDomain

// MARK: - Quick Capture (J5)
//
// Global hotkey + transient panel for capturing tasks anywhere in macOS.
// Extracted from AppDelegate.swift.

extension AppDelegate {

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

    func installQuickCaptureHotkey() {
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
    func toggleQuickCapture() {
        if quickCaptureWindow != nil {
            dismissQuickCapture()
        } else {
            presentQuickCapture()
        }
    }

    func presentQuickCapture() {
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
        // A content material, not `.hudWindow` — HUDs are for media/
        // overlay chrome without controls; a capture panel carries a
        // text field and hint rows, and Spotlight itself sits on a
        // standard panel material (HIG panels/materials).
        visualEffect.material = .popover
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

    func dismissQuickCapture() {
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
    func tryOpenMenuBarPopover() {
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

}
