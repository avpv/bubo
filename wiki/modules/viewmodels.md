# Module: ViewModels

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/Settings/SettingsViewModel.swift, Bubo/Presentation/Views/Settings/CloudSyncStatusSectionViewModel.swift
> **Last ingest:** 2026-05-14 (rev: `SettingsViewModel` class line `:7`→`:8`, `navigateToPaneNotification` `:12`→`:13`, `lastPaneKey` `:17`→`:18`)
> **Related:** [`views.md`](views.md), [`services.md`](services.md), [`../concepts/cloudkit-sync.md`](../concepts/cloudkit-sync.md)

## Files

| File | Lines | Type+line | Role |
|---|---:|---|---|
| `SettingsViewModel.swift` | 160 | `@MainActor @Observable class SettingsViewModel` (`:8`) | Settings window state. Static `pendingPane` (`:10`) for deep-link navigation. Posts `navigateToPaneNotification` (`Notification.Name("SettingsViewModel.navigateToPane")` at `:13`). Persists last-viewed pane in `UserDefaults` key `"BuboSettingsLastPane"` (`:18`) so `⌘,` lands the user where they were |
| `CloudSyncStatusSectionViewModel.swift` | 52 | `@MainActor struct CloudSyncStatusSectionViewModel` (`:25`) | Extracts decision logic out of `CloudSyncStatusSection`. Three duties (per header comment `:7–21`): (1) read+write the `BuboCloudSyncEnabled` flag; (2) snapshot the flag at launch so a pending toggle shows a "restart required" hint until the app relaunches — `ModelContainer` is built once per process; (3) project `CloudServicesCoordinator.summary`/`isWarning`/`isSyncInProgress` + `ReminderService.lastPersistenceError` through one VM so the view doesn't wire two environment objects. **Not `@Observable`** — value type, rebuilt every `body` render |

## Why this module is sparse

Most screens read `@Observable` services (`ReminderService`, `BacklogService`, `OptimizerService`) directly. Dedicated ViewModels are added only when:

- the screen has its own validation/transform state (settings deep-linking),
- or the screen needs to project a non-trivial sub-view of cloud-sync progress through a single object.

`CloudSyncStatusSectionViewModel` is deliberately a value type rebuilt per `body` — the comment at `:21–24` calls out that SwiftUI handles invalidation because its inputs are already observed by the view. If you find yourself adding a ViewModel just to wrap a service, prefer reading the service directly.
