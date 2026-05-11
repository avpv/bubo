# Module: app entry point

> **Kind:** module
> **Sources:** Bubo/App.swift, Bubo/AppContainer.swift, Bubo/AppDelegate.swift, Bubo/ResourceBundle.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`services.md`](services.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/quick-capture.md`](../concepts/quick-capture.md)

## Files

| File | Lines | Top-level type | Purpose |
|---|---:|---|---|
| `App.swift` | 356 | `BuboApp: App` (`@main`) at `:17` | `MenuBarExtra` scene, Core-Graphics owl-icon rendering with `MenuBarIconCache`, badge count, `.environment(...)` wiring |
| `AppContainer.swift` | 220 | `struct AppContainer` (`:24`) | Composition root — builds all services and SwiftData containers once at launch |
| `AppDelegate.swift` | 780 | `class AppDelegate: NSObject, NSApplicationDelegate` (`:27`) | Window orchestration for full-screen alerts, pinned timer, post-join ribbon, global hotkey; remote-notification entry for CloudKit |
| `ResourceBundle.swift` | 20 | `extension Bundle` with `Bundle.safeModule` (`:6`) | Safe alternative to `Bundle.module` — returns nil instead of `fatalError` when the SPM resource bundle is missing at runtime. Searches `Bubo_Bubo.bundle` in `Bundle.main.resourceURL` and `Bundle.main.bundleURL` |

## BuboApp

`BuboApp` (`App.swift:17`) is a SwiftUI `App` with a single `MenuBarExtra` scene. It:

- holds **seven** container properties as `@State` (`settings`, `reminderService`, `networkMonitor`, `optimizerService`, `agentService`, `remindersSyncService`, `cloudServices`) — the full `AppContainer` is built in `init()` and its fields are unpacked individually (`App.swift:33–42`),
- renders the owl icon **via Core Graphics** (`drawOwl(in:size:color:)` at `App.swift:44`) plus a thin density bar indicating calendar load (J2, `drawDensityBar` at `App.swift:205`),
- caches the rendered icon image in a private `MenuBarIconCache` (`App.swift:4`) keyed by `(count, skinID, densityBucket)` so repaints only happen when the visible state actually changes,
- maintains the dock-tile badge using `reminderService.badgeCount` (`App.swift:156`),
- injects services into the SwiftUI environment for `MenuBarView` and the `Settings` scene (`App.swift:314–353`).

Source-compat shim at `App.swift:31`: `BuboApp.cloudSyncPreferenceKey` re-exports `AppContainer.cloudSyncPreferenceKey` so older views reading the key via `BuboApp` keep compiling.

## AppContainer

220-line `@MainActor struct` (`AppContainer.swift:23–24`). Two entry points:

- `make()` (`AppContainer.swift:58`): production path. Reads `cloudSyncPreferenceKey = "BuboCloudSyncEnabled"` (`:31`). Opens three resilient SwiftData containers (`EventCache.store`, `UserEvents.store`, `Backlog.store` in Application Support, paths declared at `:33–38`). Builds `CloudServicesCoordinator` and conditionally calls `start(containerIdentifier: "iCloud.<bundleId>")` (`:82`). Delegates to `build(...)`.
- `build(...)` (`AppContainer.swift:111`): pure wiring. In order: `NetworkMonitor`, `AgentService`, `ReminderService(settings:, eventCacheContainer:, userEventsContainer:)`, `BacklogService(modelContainer:)`, `OptimizerService()` (then `.backlogService` and `.energyCheckInService = EnergyCheckInService()` are assigned at `:132–133`), `RemindersSyncService(settings:, backlogService:)`.

Output properties (`AppContainer.swift:42–49`): `settings`, `networkMonitor`, `agentService`, `cloudServices`, `reminderService`, `backlogService`, `optimizerService`, `remindersSyncService`. Note: `EnergyCheckInService` is not a top-level container property — it is constructed inline and attached to `OptimizerService` inside `build(...)`.

`resilientContainer(...)` (`AppContainer.swift:193`) wraps each container build: retries with CloudKit disabled if mirroring fails, falls back to a clean local store if the file is corrupt (deletes `.store` plus `-wal`/`-shm` sidecars then rebuilds).

Live cloud-sync toggling requires app restart — `ModelContainer` is built once per process.

## AppDelegate responsibilities

AppKit-only concerns that don't fit cleanly in SwiftUI. Logger subsystem `com.avpv.Bubo`, category `App/Lifecycle` (`AppDelegate.swift:5`).

- **Window subclasses:** `KeyableWindow: NSWindow` (`:7`) and `KeyablePanel: NSPanel` (`:21`) override `canBecomeKey`/`canBecomeMain` and route `keyDown` events through the SwiftUI responder chain. Without the override, borderless windows beep on every keystroke and `.keyboardShortcut` / `.onKeyPress` never fire.
- **Full-screen meeting alerts (J4):** listens for `.showFullScreenAlert` (`AppDelegate.swift:59`). Maintains a FIFO `pendingAlerts: [(event, minutesBefore, nextEvent)]` queue (`:33`) — if an alert is already up, new ones queue; on dismiss, `showNextPendingAlert()` (`:185`) pops, skipping events whose `startDate` has already passed. See [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md).
- **Pinned timer window:** listens for `.pinTimerWindow` (`:75`) / `.unpinTimerWindow` (`:86`). Floating `KeyablePanel` with `NSVisualEffectView` material `.popover`, level `.floating`, hosts `TimerScreenView` (`:206`).
- **Global quick-capture hotkey (⌃⇧⌘Space, J5):** `installQuickCaptureHotkey()` (`:100`) — uses local + global `NSEvent` monitors. See [`../concepts/quick-capture.md`](../concepts/quick-capture.md).
- **Post-join ribbon (J1):** thin banner with auto-dismiss task. See [`../concepts/join-ribbon.md`](../concepts/join-ribbon.md).
- **CloudKit remote notifications:** `applicationDidFinishLaunching` calls `NSApp.registerForRemoteNotifications()` (`:57`) so `NSPersistentCloudKitContainer` receives silent pushes. No-op without the APS entitlement; CloudKit still works in pull mode.
- **Settings-window dock-leak workaround** (`:116–129`): the SwiftUI `Settings` scene leaves the app in the Dock as `.regular` activation policy. AppDelegate listens for `NSWindow.willCloseNotification` and resets to `.accessory` only when (a) the window was real (visible) and titled "Settings", and (b) the current policy is `.regular`. Three rules cited at `:102–115`: never `NSApp.hide(nil)` (breaks MenuBarExtra), ignore SwiftUI scaffold windows that briefly match the title, do not set `.accessory` while already `.accessory` (breaks MenuBarExtra).

## What is NOT here

- Settings UI — lives in `Views/Settings/` and is opened by a SwiftUI `Settings` scene from `BuboApp`.
- Any business logic — `AppDelegate` is windowing only; logic lives in services.
