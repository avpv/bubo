# Full-screen meeting alerts (J4)

> **Kind:** concept
> **Sources:** Bubo/Composition/AppDelegate/AppDelegate.swift, Bubo/Composition/AppDelegate/AppDelegate+Alerts.swift, Bubo/Presentation/Views/FullScreenAlert/FullScreenAlertView.swift, Bubo/Infrastructure/Notifications/NotificationScheduler.swift, Bubo/Application/Reminders/ReminderService.swift, Sources/Domain/Reminders/ReminderSettings.swift
> **Last ingest:** 2026-07-25 (rev: added the «Deleted events» section; line refs bumped — `NotificationScheduler.swift` gate `:235`, post `:387`, decl `:431`; `AppDelegate.swift` observer `:70`, `pendingAlerts` `:39`, `KeyableWindow` `:8–20`; `AppDelegate+Alerts.swift` enqueue `:18`, `showNextPendingAlert` `:67`)
> **Related:** [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../modules/app.md`](../modules/app.md)

## What

The defining product feature: before a meeting, **the entire screen goes dark** with a countdown timer and meeting title. The user cannot accidentally swipe it away. Multiple reminder intervals (e.g. 30/10/1 min) can stack so the alerts grow more urgent.

## How it fires

1. `ReminderService` publishes `upcomingEvents`.
2. `NotificationScheduler` (`Infrastructure/Notifications/NotificationScheduler.swift`) reads each event's `reminderIntervals` (from `ReminderSettings` + per-event `ReminderOverrideStore`) and schedules `UserNotifications` triggers.
3. When a trigger fires and `ReminderSettings.showFullScreenAlert` is on (gate at `NotificationScheduler.swift:235`), the scheduler posts `Notification.Name.showFullScreenAlert` (`NotificationScheduler.swift:387`, declared at `:431`) with `userInfo` `["event": CalendarEvent, "minutesBefore": Int, "nextEvent": CalendarEvent?]`.
4. `AppDelegate` observes that name (`AppDelegate.swift:70`). The observer routes via `enqueueAlert(event:minutesBefore:nextEvent:)` (`AppDelegate+Alerts.swift:18`) which either shows the alert immediately or appends to `pendingAlerts`.
5. The alert window is a `KeyableWindow` (overrides `canBecomeKey`/`canBecomeMain` so keyboard shortcuts work — `AppDelegate.swift:8–20`) hosting `FullScreenAlertView` with countdown, title, and join/dismiss actions.
6. A small `UserNotifications` banner is also posted as a fallback in case the windowing path fails.

The pending-alert queue (`pendingAlerts` at `AppDelegate.swift:39`) is FIFO. On dismiss, `showNextPendingAlert()` (`AppDelegate+Alerts.swift:67`) pops and skips entries whose `startDate` has already passed — no point showing an alert that would auto-dismiss immediately.

## Dismissal

The alert dismisses on join, on snooze, or when the meeting begins. Snooze posts a `.snoozeReminder` notification consumed by `NotificationScheduler` to re-arm with the chosen offset.

## Deleted events

A deleted event must not keep alerting. Three layers, because a delete can land before the timer fires, between fire and dismiss, or in a partial state:

| Layer | Where | What it does |
|---|---|---|
| Reconcile | `NotificationScheduler.reconcile(liveEventIds:)` (`:195`), called from `ReminderService`'s `onEventsUpdated` (`ReminderService.swift:204`) | Cancels timers for every id missing from the live set. `schedule(_:)` alone cannot: it only touches the events it is handed, so an event that stops arriving keeps its timers. |
| Fire-time guard | `NotificationScheduler.fire` (`:231`) and `firePhaseAlert` (`:334`) | A timer can outlive its event by the gap between the delete landing and the next reconcile. Both bail when `knownEvents` no longer holds the id. |
| Surface teardown | `AppDelegate.dismissAlerts(forEventIds:)` (`AppDelegate+Alerts.swift:32`), driven by `.eventsDidDisappear` (`AppDelegate.swift:90`) | Drops queued alerts, tears down the alert on screen when it is the deleted event's, dismisses the Join ribbon, and nils out a vanished back-to-back `nextEvent` heads-up. |

The live set is the **complete** one — external slice plus every expanded local occurrence (`ReminderService.liveEventIds(external:)` at `:272`). Local events never arrive through `EventKitSyncCoordinator`, so folding them in explicitly is what stops the reconcile pass from reading them as deleted on the next sync tick.

`.eventsDidDisappear` is posted from three places (`ReminderService.notifyEventsDisappeared(_:)` at `:286`): the reconcile result, `removeLocalEvent(id:)`, `excludeOccurrence(occurrenceId:)`, and the occurrences an `updateLocalEvent(_:)` edit drops.

`knownEvents` (keyed by id) also backs the J4 back-to-back lookup. It is **merged** on `schedule(_:)`, not replaced — callers legitimately pass partial slices (one local event, one reminder-override edit), and the previous `lastScheduledEvents = events` assignment let such a call shrink the scheduler's world to a single event.

## Wallpaper

The alert background is a `WallpaperDefinition` (`Presentation/Views/Skins/Wallpaper/WallpaperDefinition.swift`) chosen by the user in `AppearanceTabView`. Stock wallpaper images ship under `Bubo/Resources/`.

## Cross-references

- The pre-meeting flow is paired with the post-join flow (`JoinRibbonView`) — see [`join-ribbon.md`](join-ribbon.md).
- Per-event customizations (intervals, custom title) live in `ReminderOverrideStore` and `EventAttributeOverrideStore`.
