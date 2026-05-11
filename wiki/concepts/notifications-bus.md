# Notifications bus

> **Kind:** concept
> **Sources:** Bubo/Services/, Bubo/AppDelegate.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`../modules/services.md`](../modules/services.md)

## What

Bubo uses `NotificationCenter` for cross-cutting events that don't fit neatly into `@Observable` property reads — things like "a task was added", "calendar data changed", "an alert should snooze". This avoids tight coupling between services and `AppDelegate`/UI consumers.

## Known topics

| Notification | Posted by | Consumed by |
|---|---|---|
| `calendarDataChanged` | `AppleCalendarService` | `EventKitSyncCoordinator`, `EventCache` |
| `.taskAdded` | `BacklogService` | `OptimizerService` (re-optimize), UI |
| `.taskUpdated` | `BacklogService` | Same |
| `.taskRemoved` | `BacklogService` | Same |
| `.taskCompleted` | `BacklogService` | `PomodoroHistoryService` if a Pomodoro completed, plus stats |
| `.snoozeReminder` | `FullScreenAlertView` (via `AppDelegate`) | `NotificationScheduler` (re-arms) |
| `.didFinishImport` | `CloudKitSyncMonitor` | `UpsertReconciler`, settings UI badge |

The list may drift — re-grep `NotificationCenter.default.post(name:` and `Notification.Name(` during ingest.

## When to use vs `@Observable`

- **`@Observable` property:** when a view re-renders from a change. Direct, type-safe, automatic dependency tracking.
- **`NotificationCenter`:** when N services in unrelated parts of the graph care about the same edge event, or when the consumer is `AppDelegate` (not a SwiftUI view).

Avoid using `NotificationCenter` to communicate state that has a natural home as a service property.
