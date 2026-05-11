# Event pipeline

> **Kind:** architecture
> **Sources:** Bubo/Infrastructure/Apple/, Bubo/Application/Reminders/ReminderService.swift, Bubo/Infrastructure/Reminders/EventKitSyncCoordinator.swift, Bubo/Infrastructure/Reminders/NotificationScheduler.swift, Bubo/Composition/AppDelegate.swift
> **Last ingest:** 2026-05-12 (rev: bounded-context restructure + mega-file split)
> **Related:** [`overview.md`](overview.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md)

## End-to-end path

```
EventKit (EKEvent)
  → AppleCalendarEventSource (Services/Apple/CalendarEventSource.swift)
      conforms to CalendarEventSource protocol
  → EventKitSyncCoordinator (Services/Reminders/)
      polls + listens for EKEventStoreChanged
      applies ExcludedOccurrenceStore tombstones
      applies EventAttributeOverrideStore overlays
  → ReminderService.upcomingEvents : [CalendarEvent]    (@Observable)
  → consumed by:
      ├─ MenuBarView (timeline render)
      ├─ NotificationScheduler (per-event alert timers)
      ├─ OptimizerService (input to GA)
      └─ AppDelegate (sets up full-screen alert windows when timers fire)
```

## Why a wrapper type

`CalendarEvent` (in `Domain/CalendarEvent.swift`) is Bubo's own value type — not `EKEvent`. The wrapper exists because:

- the app stores per-event overlays (color tag, reminder overrides, Pomodoro phase markers) that EventKit can't represent;
- the optimizer needs a `Sendable`, deterministic representation it can hash and shuffle;
- locally-created events live in SwiftData (`PersistedLocalEvent`) and must coexist with EventKit-sourced events behind a single type.

Conversion lives in `Optimizer/Models/EventConversion.swift` for the GA boundary.

## Local edits vs EventKit events

EventKit events are read-mostly. Bubo offers limited writes (create/edit) when the user picks a writable calendar; otherwise edits are stored as **overlays** in `EventAttributeOverrideStore` (color, custom name) or as **locally-authored** events in `LocalEventStore`. The merge happens in `EventKitSyncCoordinator`.

## Recurrence

Recurring events are expanded by `RecurrenceExpander` (`Domain/RecurrenceExpander.swift`). Individual occurrences that the user "deleted" are kept as tombstones in `ExcludedOccurrenceStore` so a single skip doesn't kill the series.

## Alert path

Per-event alert timers are scheduled by `NotificationScheduler` (`Infrastructure/Reminders/NotificationScheduler.swift`) based on `ReminderSettings.reminderIntervals` and per-event overrides from `ReminderOverrideStore`. When a timer fires:

1. A local `UserNotifications` banner is posted (fallback).
2. If `ReminderSettings.showFullScreenAlert` is on, the scheduler posts `Notification.Name.showFullScreenAlert`. `AppDelegate` observes it and presents `FullScreenAlertView` on every active screen. See [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md).
