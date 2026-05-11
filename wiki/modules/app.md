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

Build order in `AppContainer.make()`:

1. `ReminderSettings.load()` (UserDefaults + KVS).
2. Three `ModelContainer`s (see [`../architecture/persistence.md`](../architecture/persistence.md)).
3. `CloudServicesCoordinator`, `NetworkMonitor`, `AgentService`.
4. `ReminderService` (+ its `EventKitSyncCoordinator`, `NotificationScheduler`, persistence stores).
5. `BacklogService`.
6. `OptimizerService` (owns `BuboOptimizer` + `IntentLearner`).
7. `RemindersSyncService`.

If any CloudKit container fails to build, the corresponding local-only container is substituted and a flag on `CloudServicesCoordinator` is raised.

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
