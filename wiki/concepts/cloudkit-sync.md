# CloudKit sync

> **Kind:** concept
> **Sources:** Bubo/Composition/AppContainer.swift, Bubo/Infrastructure/Cloud/CloudSyncService.swift, Bubo/Infrastructure/Cloud/CloudSyncProtocols.swift, Bubo/Infrastructure/Cloud/CloudKitSyncMonitor.swift, Bubo/Infrastructure/Cloud/CloudServicesCoordinator.swift, Bubo/Infrastructure/Persistence/UpsertReconciler.swift, Bubo/Composition/AppDelegate.swift
> **Last ingest:** 2026-05-12 (rev: bounded-context restructure + mega-file split)
> **Related:** [`../architecture/persistence.md`](../architecture/persistence.md), [`../modules/services.md`](../modules/services.md)

## What

User-authored events, overrides, and backlog tasks sync across the user's Macs via SwiftData's CloudKit-backed `ModelContainer`s. EventKit events are not synced by Bubo — they sync via Apple Calendar's own iCloud machinery.

## Containers

- `UserEvents` and `Backlog` are CloudKit-backed (private database).
- `EventCache` is local-only — it is a denormalised cache rebuilt from EventKit.

See [`../architecture/persistence.md`](../architecture/persistence.md) for the full container map.

## Coordination

| Component | Role |
|---|---|
| `CloudServicesCoordinator` | Owns iCloud account state; flips containers to local-only when the account is unavailable |
| `CloudKitSyncMonitor` | Watches SwiftData CloudKit completion events; emits `.didFinishImport` |
| `UpsertReconciler` | A namespace (`enum`) with a single static `reconcile(...)` (`Infrastructure/Persistence/UpsertReconciler.swift:23`). Called by **every save path** in the persistence stores (`LocalEventStore`, `ExcludedOccurrenceStore`, `ReminderOverrideStore`, `EventAttributeOverrideStore`) — not specifically on remote import. Each pass: dedupes duplicate rows that CloudKit's merge window may have created, updates survivors, inserts new rows, deletes rows no longer desired. Caller commits |
| `AppDelegate` | Forwards push notifications: `application(_:didReceiveRemoteNotification:...)` → `CloudKitSyncMonitor` |

## Conflict resolution

Per-record last-write-wins keyed by `modifiedAt`. For `BacklogTask`s the field is on the domain type itself; for event overrides it's on the persistence record.

## Settings sync

`ReminderSettings` does **not** use CloudKit — it lives in `UserDefaults` mirrored to `NSUbiquitousKeyValueStore` (KVS). KVS is faster for small preference blobs and survives container migrations.
