# Module: app entry point

> **Kind:** module
> **Sources:** Bubo/App.swift, Bubo/AppContainer.swift, Bubo/AppDelegate.swift, Bubo/ResourceBundle.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`services.md`](services.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/quick-capture.md`](../concepts/quick-capture.md)

## Files

| File | Top-level type | Purpose |
|---|---|---|
| `App.swift` | `BuboApp` (`@main`) | Menu-bar `Scene`, owl SVG icon with density bar, badge count, `.environment(...)` wiring |
| `AppContainer.swift` | `AppContainer` | Composition root — builds all services and SwiftData containers once at launch |
| `AppDelegate.swift` | `AppDelegate` (`NSApplicationDelegate`) | Window orchestration for full-screen alerts, pinned timer, post-join ribbon, global hotkey; remote-notification entry for CloudKit |
| `ResourceBundle.swift` | `ResourceBundle` | Tiny helper for locating bundled assets |

## BuboApp

`BuboApp` is a SwiftUI `App` with a single `MenuBarExtra` scene. It:

- holds the `AppContainer` as `@State`,
- renders the owl icon plus a thin density bar (calendar load indicator) into the status item,
- maintains the dock-tile badge using `ReminderSettings.badgeCountMode`,
- injects services into the SwiftUI environment for `MenuBarView` and `SettingsScene`.

## AppContainer

220-line `@MainActor struct`. Two entry points:

- `make()` (`AppContainer.swift:55`): production path. Reads `cloudSyncPreferenceKey = "BuboCloudSyncEnabled"`. Opens three resilient SwiftData containers (`EventCache.store`, `UserEvents.store`, `Backlog.store` in Application Support). Builds `CloudServicesCoordinator` and conditionally starts it with `iCloud.<bundleId>`. Delegates to `build(...)`.
- `build(...)` (`AppContainer.swift:107`): pure wiring. In order: `NetworkMonitor`, `AgentService`, `ReminderService(settings:, eventCacheContainer:, userEventsContainer:)`, `BacklogService(modelContainer:)`, `OptimizerService()` (then `.backlogService` and `.energyCheckInService = EnergyCheckInService()` are assigned), `RemindersSyncService(settings:, backlogService:)`.

Output properties (`AppContainer.swift:48–56`): `settings`, `networkMonitor`, `agentService`, `cloudServices`, `reminderService`, `backlogService`, `optimizerService`, `remindersSyncService`. Note: `EnergyCheckInService` is not a top-level container property — it is constructed inline and attached to `OptimizerService`.

`resilientContainer(...)` (`AppContainer.swift:184`) wraps each container build: retries with CloudKit disabled if mirroring fails, falls back to a clean local store if the file is corrupt.

Live cloud-sync toggling requires app restart — `ModelContainer` is built once per process.

## AppDelegate responsibilities

AppKit-only concerns that don't fit cleanly in SwiftUI:

- **Full-screen meeting alerts (J4):** spawns `NSWindow`s sized to each `NSScreen.screens` element, hosts `FullScreenAlertView`. See [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md).
- **Pinned timer window:** floating, ignores mission-control spaces, hosts `TimerScreenView`.
- **Global quick-capture hotkey (⌃⇧⌘Space):** registers via `Carbon.HIToolbox`, presents the quick-capture overlay. See [`../concepts/quick-capture.md`](../concepts/quick-capture.md).
- **Post-join ribbon (J1):** after the user joins a meeting URL, a thin banner offers next-meeting context. See [`../concepts/join-ribbon.md`](../concepts/join-ribbon.md).
- **CloudKit remote notifications:** `application(_:didReceiveRemoteNotification:...)` forwards to `CloudKitSyncMonitor`.

## What is NOT here

- Settings UI — lives in `Views/Settings/` and is opened by a SwiftUI `Settings` scene from `BuboApp`.
- Any business logic — `AppDelegate` is windowing only; logic lives in services.
