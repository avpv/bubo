# Module: ViewModels

> **Kind:** module
> **Sources:** Bubo/ViewModels/
> **Last ingest:** 2026-05-11
> **Related:** [`views.md`](views.md), [`services.md`](services.md), [`../concepts/cloudkit-sync.md`](../concepts/cloudkit-sync.md)

## Files

| File | Type | Used by |
|---|---|---|
| `SettingsViewModel.swift` | `SettingsViewModel` | `SettingsView` + tabs |
| `CloudSyncStatusSectionViewModel.swift` | `CloudSyncStatusSectionViewModel` | A section in `GeneralTabView` / `SettingsView` |

## Why this module is sparse

Most screens read `@Observable` services (`ReminderService`, `BacklogService`, `OptimizerService`) directly. A dedicated `ViewModel` is added only when:

- the screen has its own validation/transform state (settings form fields),
- or the screen needs to project a non-trivial sub-view of cloud-sync progress.

If you find yourself adding a ViewModel just to wrap a service, prefer reading the service directly.
