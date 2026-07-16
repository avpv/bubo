# Module: app entry point

> **Kind:** module
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Composition/App/AppContainer.swift, Bubo/Composition/AppDelegate/AppDelegate.swift, Bubo/Composition/AppDelegate/AppDelegate+Alerts.swift, Bubo/Composition/AppDelegate/AppDelegate+PinnedTimer.swift, Bubo/Composition/AppDelegate/AppDelegate+QuickCapture.swift, Bubo/Composition/AppDelegate/AppDelegate+JoinRibbon.swift, Bubo/Infrastructure/Bundle/ResourceBundle.swift
> **Last ingest:** 2026-07-16 (PR #595: menu bar icon no longer follows skin accent colour — `useSkinIcon`/`resolvedIconColor()`/`skinID` removed from `App.swift`; line refs re-based, file now 320 lines)
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`services.md`](services.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/quick-capture.md`](../concepts/quick-capture.md)

## Files

| File | Lines | Top-level type | Purpose |
|---|---:|---|---|
| `Composition/App/App.swift` | 320 | `BuboApp: App` (`@main` at `:16`, struct at `:17`) | `MenuBarExtra` scene, Core-Graphics owl-icon rendering with `MenuBarIconCache`, badge count, `.environment(...)` wiring |
| `Composition/App/AppContainer.swift` | 217 | `@MainActor struct AppContainer` (`:19–20`) | Composition root — builds all services and SwiftData containers once at launch |
| `Composition/AppDelegate/AppDelegate.swift` | 189 | `class AppDelegate: NSObject, NSApplicationDelegate` (`@MainActor` at `:27`, class at `:28`) | Imports, stored properties, lifecycle (`applicationDidFinishLaunching` / `applicationWillTerminate`), `NSWindowDelegate` conformance, `Notification.Name` constants |
| `Composition/AppDelegate/AppDelegate+Alerts.swift` | 212 | `extension AppDelegate` | Full-screen alert window + `pendingAlerts` queue helpers (`enqueueAlert`, `tearDownAlertWindow`, `showNextPendingAlert`, `dismissAlert`, `showAlert`) |
| `Composition/AppDelegate/AppDelegate+PinnedTimer.swift` | 86 | `extension AppDelegate` | Floating pinned-timer panel (`showPinnedTimer`, `dismissPinnedTimer`) |
| `Composition/AppDelegate/AppDelegate+QuickCapture.swift` | 225 | `extension AppDelegate` | J5 global hotkey + capture panel (`installQuickCaptureHotkey`, `toggleQuickCapture`, `presentQuickCapture`, `dismissQuickCapture`, `tryOpenMenuBarPopover`) |
| `Composition/AppDelegate/AppDelegate+JoinRibbon.swift` | 117 | `extension AppDelegate` | J1 post-join ribbon (`presentJoinRibbon`, `dismissJoinRibbon`) |
| `Infrastructure/Bundle/ResourceBundle.swift` | 20 | `extension Bundle` with `Bundle.safeModule` (`:6`) | Safe alternative to `Bundle.module` — returns nil instead of `fatalError` when the SPM resource bundle is missing at runtime. Searches `Bubo_Bubo.bundle` in `Bundle.main.resourceURL` and `Bundle.main.bundleURL`. Lives in its own `Infrastructure/Bundle/` subdirectory (peer of `Security/`, `Network/`, `Cache/`). |

## BuboApp

`BuboApp` (`App.swift:17`) is a SwiftUI `App` with a single `MenuBarExtra` scene. It:

- holds **seven** container properties as `@State` (`settings`, `reminderService`, `networkMonitor`, `optimizerService`, `agentService`, `remindersSyncService`, `cloudServices`) — the full `AppContainer` is built in `init()` (`App.swift:33`) and its fields are unpacked individually,
- renders the owl icon **via Core Graphics** (`drawOwl(in:size:color:)` at `App.swift:44`) plus a thin density bar indicating calendar load (J2, `drawDensityBar` at `App.swift:171`),
- caches the rendered icon image in a private `MenuBarIconCache` (`App.swift:5`) keyed by `(count, densityBucket)` so repaints only happen when the visible state actually changes — the menu bar icon no longer follows the active skin's accent colour (PR #595): it is always a template image, painted black and left for the system to render appearance-appropriate (white on dark, black on light),
- maintains the dock-tile badge using `reminderService.badgeCount` (`App.swift:121–122`),
- injects services into the SwiftUI environment for `MenuBarView` and the `Settings` scene (around `App.swift:288–293`, `301–306`, `314`).

Source-compat shim at `App.swift:31`: `BuboApp.cloudSyncPreferenceKey` re-exports `AppContainer.cloudSyncPreferenceKey` so older views reading the key via `BuboApp` keep compiling.

## AppContainer

217-line `@MainActor struct` (`AppContainer.swift:19–20`). Two entry points:

- `make()` (`AppContainer.swift:54`): production path. Reads `cloudSyncPreferenceKey = "BuboCloudSyncEnabled"` (`:27`). Opens three resilient SwiftData containers via `resilientContainer(...)` at `:61` / `:66` / `:71` (`EventCache.store`, `UserEvents.store`, `Backlog.store` in Application Support). Builds `CloudServicesCoordinator` and conditionally calls `start(containerIdentifier: "iCloud.<bundleId>")`. Delegates to `build(...)`.
- `build(...)` (`AppContainer.swift:107`): pure wiring. In order: `NetworkMonitor`, `AgentService`, `ReminderService(settings:, eventCacheContainer:, userEventsContainer:)`, `BacklogService(modelContainer:)`, `OptimizerService()` (then `.backlogService` and `.energyCheckInService = EnergyCheckInService()` are assigned inside `build`), `RemindersSyncService(settings:, backlogService:)`.

Output properties on the struct: `settings`, `networkMonitor`, `agentService`, `cloudServices`, `reminderService`, `backlogService`, `optimizerService`, `remindersSyncService`. Note: `EnergyCheckInService` is not a top-level container property — it is constructed inline and attached to `OptimizerService` inside `build(...)`.

`resilientContainer(...)` (`AppContainer.swift:190`) wraps each container build: retries with CloudKit disabled if mirroring fails, falls back to a clean local store if the file is corrupt (deletes `.store` plus `-wal`/`-shm` sidecars then rebuilds).

Live cloud-sync toggling requires app restart — `ModelContainer` is built once per process.

## AppDelegate responsibilities

AppKit-only concerns that don't fit cleanly in SwiftUI. Logger subsystem `com.avpv.Bubo`, category `App/Lifecycle` (`AppDelegate.swift:5`).

- **Window subclasses:** `KeyableWindow: NSWindow` (`:8`) and `KeyablePanel: NSPanel` (`:22`) override `canBecomeKey`/`canBecomeMain` and route `keyDown` events through the SwiftUI responder chain. Without the override, borderless windows beep on every keystroke and `.keyboardShortcut` / `.onKeyPress` never fire.
- **Full-screen meeting alerts (J4):** listens for `.showFullScreenAlert` (`AppDelegate.swift:61`). Maintains a FIFO `pendingAlerts: [(event, minutesBefore, nextEvent)]` queue (`:34`) — if an alert is already up, new ones queue; on dismiss, `showNextPendingAlert()` (in `AppDelegate+Alerts.swift`) pops, skipping events whose `startDate` has already passed. See [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md).
- **Pinned timer window:** listens for `.pinTimerWindow` (`AppDelegate.swift:77`) / `.unpinTimerWindow` (`:88`). Floating `KeyablePanel` with `NSVisualEffectView` material `.popover`, level `.floating`, hosts `TimerScreenView` (in `AppDelegate+PinnedTimer.swift`).
- **Global quick-capture hotkey (⌃⇧⌘Space, J5):** `installQuickCaptureHotkey()` called from `applicationDidFinishLaunching` (`AppDelegate.swift:101`); implementation in `AppDelegate+QuickCapture.swift` uses local + global `NSEvent` monitors. See [`../concepts/quick-capture.md`](../concepts/quick-capture.md).
- **Post-join ribbon (J1):** thin banner with auto-dismiss task. See [`../concepts/join-ribbon.md`](../concepts/join-ribbon.md).
- **CloudKit remote notifications:** `applicationDidFinishLaunching` calls `NSApp.registerForRemoteNotifications()` (`:58`) so `NSPersistentCloudKitContainer` receives silent pushes. No-op without the APS entitlement; CloudKit still works in pull mode.
- **Settings-window dock-leak workaround** (observer at `:118`): the SwiftUI `Settings` scene leaves the app in the Dock as `.regular` activation policy. AppDelegate listens for `NSWindow.willCloseNotification` and resets to `.accessory` only when (a) the window was real (visible) and titled "Settings", and (b) the current policy is `.regular`. The doc comment around the observer enumerates the three rules: never `NSApp.hide(nil)` (breaks MenuBarExtra), ignore SwiftUI scaffold windows that briefly match the title, do not set `.accessory` while already `.accessory` (breaks MenuBarExtra).

## What is NOT here

- Settings UI — lives in `Presentation/Views/Settings/` and is opened by a SwiftUI `Settings` scene from `BuboApp`.
- Any business logic — `AppDelegate` is windowing only; logic lives in services.
