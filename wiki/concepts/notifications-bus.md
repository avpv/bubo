# Notifications bus

> **Kind:** concept
> **Sources:** Bubo/Application/, Bubo/Infrastructure/, Bubo/Composition/AppDelegate/AppDelegate.swift, Sources/Domain/Reminders/ReminderSettings.swift, Bubo/Presentation/Views/Timer/TimerScreenView.swift, Bubo/Presentation/Views/Settings/SettingsViewModel.swift
> **Last ingest:** 2026-07-25 (rev: new `.eventsDidDisappear` row; `NotificationScheduler` decl `:438`/`showFullScreenAlert` decl `:431`/post `:387`, `AppDelegate` notification names `:214–228`, alert listener `:70`, disappearance listener `:90`)
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`../modules/services.md`](../modules/services.md), [`full-screen-alerts.md`](full-screen-alerts.md)

## What

Bubo uses `NotificationCenter` for cross-cutting events that don't fit `@Observable` property reads — edge events ("a task was added"), AppKit-side actions ("snooze this alert"), and module-spanning signals ("CloudKit import finished").

## Known topics

Verified by grepping `Notification.Name(` and `NotificationCenter.default.post` across `Bubo/`. List as of last ingest.

| Name | Declared in | Posted by | Listened by |
|---|---|---|---|
| `AppleCalendarService.calendarDataChanged` | `Infrastructure/Apple/AppleCalendarService.swift:25` | `AppleCalendarService` (on `EKEventStoreChanged` + auth flips) | `EventKitSyncCoordinator`, `EventCache` |
| `AppleCalendarService.authorizationDidChange` | `Infrastructure/Apple/AppleCalendarService.swift:31` | `AppleCalendarService` | Settings UI |
| `AppleRemindersService.remindersDataChanged` | `Infrastructure/Apple/AppleRemindersService.swift:25` | `AppleRemindersService` | `RemindersSyncService` |
| `AppleRemindersService.authorizationDidChange` | `Infrastructure/Apple/AppleRemindersService.swift:32` | `AppleRemindersService` | Settings UI |
| `BacklogService.taskAdded` | `Application/Backlog/BacklogService.swift:24` | `BacklogService` (insert) | UI, optimizer triggers |
| `BacklogService.taskUpdated` | `Application/Backlog/BacklogService.swift:29` | `BacklogService` (mutation) | UI |
| `BacklogService.taskRemoved` | `Application/Backlog/BacklogService.swift:19` | `BacklogService` (delete) | UI |
| `BacklogService.taskCompleted` | `Application/Backlog/BacklogService.swift:14` | `BacklogService` (mark done) | `PomodoroHistoryService` |
| `BacklogService.taskScheduleChanged` | `Application/Backlog/BacklogService.swift:34` | `BacklogService` (slot/date change) | Optimizer, UI |
| `CloudKitSyncMonitor.didFinishImport` | `Infrastructure/Cloud/CloudKitSyncMonitor.swift:32` | `CloudKitSyncMonitor` | `UpsertReconciler`, settings UI |
| `CloudSyncService.didReceiveRemoteChange` | `Infrastructure/Cloud/CloudSyncService.swift:44` (forwards `DomainCloudSync.didReceiveRemoteChange`) | `CloudSyncService` (KVS merge) | Settings UI |
| `RemindersSyncService.didImportTasks` | `Application/Reminders/RemindersSyncService.swift:60` | `RemindersSyncService` | UI, backlog refresh |
| `NotificationScheduler.showFullScreenAlert` | `Infrastructure/Notifications/NotificationScheduler.swift:431` | `NotificationScheduler` (per-event timer fires, posted at `:387`) | `AppDelegate` (`AppDelegate.swift:70`) presents `FullScreenAlertView` |
| `.eventsDidDisappear` | `Infrastructure/Notifications/NotificationScheduler.swift:438` | `ReminderService.notifyEventsDisappeared(_:)` (`Application/Reminders/ReminderService.swift:286`) — reconcile result, local delete, occurrence exclusion, dropped occurrences after an edit | `AppDelegate` (`AppDelegate.swift:90`) → `dismissAlerts(forEventIds:)` tears down alerts/ribbon for deleted events |
| `.snoozeReminder` | `AppDelegate.swift:214` | `FullScreenAlertView` / `AppDelegate` | `NotificationScheduler` (re-arm) |
| `.pinTimerWindow` | `AppDelegate.swift:215` | `TimerScreenView` | `AppDelegate` |
| `.unpinTimerWindow` | `AppDelegate.swift:216` | `TimerScreenView` | `AppDelegate` |
| `.didCaptureBacklogTask` | `AppDelegate.swift:221` | `QuickCaptureView` / `AppDelegate` | `BacklogService` consumers |
| `.didCaptureBacklogTaskWithDetails` | `AppDelegate.swift:228` | `QuickCaptureView` | `MenuBarView` (opens `NewTaskView` with prefill) |
| `ReminderSettings.settingsDidChange` | `Domain/Reminders/ReminderSettings.swift:97` | `ReminderSettings` (any property set) | Most services with settings-dependent state |
| `SettingsViewModel.navigateToPaneNotification` | `Presentation/Views/Settings/SettingsViewModel.swift:13` | Various deep-link entry points | `SettingsView` |

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
