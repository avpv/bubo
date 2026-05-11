# Notifications bus

> **Kind:** concept
> **Sources:** Bubo/Services/, Bubo/AppDelegate.swift, Bubo/Models/Domain/ReminderSettings.swift, Bubo/Views/TimerScreenView.swift, Bubo/ViewModels/SettingsViewModel.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`../modules/services.md`](../modules/services.md), [`full-screen-alerts.md`](full-screen-alerts.md)

## What

Bubo uses `NotificationCenter` for cross-cutting events that don't fit `@Observable` property reads — edge events ("a task was added"), AppKit-side actions ("snooze this alert"), and module-spanning signals ("CloudKit import finished").

## Known topics

Verified by grepping `Notification.Name(` and `NotificationCenter.default.post` across `Bubo/`. List as of last ingest.

| Name | Declared in | Posted by | Listened by |
|---|---|---|---|
| `AppleCalendarService.calendarDataChanged` | `Services/Apple/AppleCalendarService.swift:24` | `AppleCalendarService` (on `EKEventStoreChanged` + auth flips) | `EventKitSyncCoordinator`, `EventCache` |
| `AppleCalendarService.authorizationDidChange` | `Services/Apple/AppleCalendarService.swift:30` | `AppleCalendarService` | Settings UI |
| `AppleRemindersService.remindersDataChanged` | `Services/Apple/AppleRemindersService.swift:24` | `AppleRemindersService` | `RemindersSyncService` |
| `AppleRemindersService.authorizationDidChange` | `Services/Apple/AppleRemindersService.swift:31` | `AppleRemindersService` | Settings UI |
| `BacklogService.taskAdded` | `Services/BacklogService.swift:23` | `BacklogService` (insert) | UI, optimizer triggers |
| `BacklogService.taskUpdated` | `Services/BacklogService.swift:28` | `BacklogService` (mutation) | UI |
| `BacklogService.taskRemoved` | `Services/BacklogService.swift:18` | `BacklogService` (delete) | UI |
| `BacklogService.taskCompleted` | `Services/BacklogService.swift:13` | `BacklogService` (mark done) | `PomodoroHistoryService` |
| `BacklogService.taskScheduleChanged` | `Services/BacklogService.swift:33` | `BacklogService` (slot/date change) | Optimizer, UI |
| `CloudKitSyncMonitor.didFinishImport` | `Services/CloudKitSyncMonitor.swift:31` | `CloudKitSyncMonitor` | `UpsertReconciler`, settings UI |
| `CloudSyncService.didReceiveRemoteChange` | `Services/CloudSyncService.swift:39` | `CloudSyncService` (KVS merge) | Settings UI |
| `RemindersSyncService.didImportTasks` | `Services/RemindersSyncService.swift:60` | `RemindersSyncService` | UI, backlog refresh |
| `NotificationScheduler.showFullScreenAlert` | `Services/Reminders/NotificationScheduler.swift:360` | `NotificationScheduler` (per-event timer fires) | `AppDelegate` (`AppDelegate.swift:60`) presents `FullScreenAlertView` |
| `.snoozeReminder` | `AppDelegate.swift:765` | `FullScreenAlertView` / `AppDelegate` | `NotificationScheduler` (re-arm) |
| `.pinTimerWindow` | `AppDelegate.swift:766` | `TimerScreenView` | `AppDelegate` |
| `.unpinTimerWindow` | `AppDelegate.swift:767` | `TimerScreenView` | `AppDelegate` |
| `.didCaptureBacklogTask` | `AppDelegate.swift:772` | `QuickCaptureView` / `AppDelegate` | `BacklogService` consumers |
| `.didCaptureBacklogTaskWithDetails` | `AppDelegate.swift:779` | `QuickCaptureView` | `MenuBarView` (opens `NewTaskView` with prefill) |
| `ReminderSettings.settingsDidChange` | `Models/Domain/ReminderSettings.swift:97` | `ReminderSettings` (any property set) | Most services with settings-dependent state |
| `SettingsViewModel.navigateToPaneNotification` | `ViewModels/SettingsViewModel.swift:12` | Various deep-link entry points | `SettingsView` |

The two anchor-naming patterns: most service-scoped notifications are declared as `static let foo` on the service (consumers reference `AppleCalendarService.calendarDataChanged`); a few app-wide ones live in `extension Notification.Name { static let foo = ... }` in `AppDelegate.swift` and `NotificationScheduler.swift` and are referenced as `.foo`.

## When to use vs `@Observable`

- **`@Observable` property:** when a view re-renders from a change. Direct, type-safe, automatic dependency tracking.
- **`NotificationCenter`:** when N services in unrelated parts of the graph care about the same edge event, or when the consumer is `AppDelegate` (windowing) rather than a SwiftUI view.

Avoid `NotificationCenter` for state that has a natural home as a service property.

## Ingest checklist

When ingesting a change that touches notifications:

1. `grep -rn "Notification.Name(" Bubo/` and reconcile this table.
2. For every new name, identify the post-er(s) and listener(s) and add a row.
3. For every removed name, scan for stale listeners.
