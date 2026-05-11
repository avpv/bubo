# Full-screen meeting alerts (J4)

> **Kind:** concept
> **Sources:** Bubo/AppDelegate.swift, Bubo/Views/FullScreenAlertView.swift, Bubo/Services/Reminders/NotificationScheduler.swift, Bubo/Models/Domain/ReminderSettings.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../modules/app.md`](../modules/app.md)

## What

The defining product feature: before a meeting, **the entire screen goes dark** with a countdown timer and meeting title. The user cannot accidentally swipe it away. Multiple reminder intervals (e.g. 30/10/1 min) can stack so the alerts grow more urgent.

## How it fires

1. `ReminderService` publishes `upcomingEvents`.
2. `NotificationScheduler` (`Services/Reminders/NotificationScheduler.swift`) reads each event's `reminderIntervals` (from `ReminderSettings` + per-event `ReminderOverrideStore`) and schedules `UserNotifications` triggers.
3. When a trigger fires and `ReminderSettings.showFullScreenAlert` is on (gate at `NotificationScheduler.swift:184`), the scheduler posts `Notification.Name.showFullScreenAlert` (`NotificationScheduler.swift:332`, declared at `:360`) with `userInfo` `["event": CalendarEvent, "minutesBefore": Int, "nextEvent": CalendarEvent?]`.
4. `AppDelegate` observes that name (`AppDelegate.swift:60`). If no alert is currently up, it spawns the alert window; otherwise it appends to `pendingAlerts` (`:172–180`).
5. The alert window is a `KeyableWindow` (overrides `canBecomeKey`/`canBecomeMain` so keyboard shortcuts work — `AppDelegate.swift:7–19`) hosting `FullScreenAlertView` with countdown, title, and join/dismiss actions.
6. A small `UserNotifications` banner is also posted as a fallback in case the windowing path fails.

The pending-alert queue (`pendingAlerts` at `AppDelegate.swift:34`) is FIFO. On dismiss, `showNextPendingAlert()` (`:188`) pops and skips entries whose `startDate` has already passed — no point showing an alert that would auto-dismiss immediately.

## Dismissal

The alert dismisses on join, on snooze, or when the meeting begins. Snooze posts a `.snoozeReminder` notification consumed by `NotificationScheduler` to re-arm with the chosen offset.

## Wallpaper

The alert background is a `WallpaperDefinition` (`Models/Domain/WallpaperDefinition.swift`) chosen by the user in `AppearanceTabView`. Stock wallpapers ship under `Resources/`.

## Cross-references

- The pre-meeting flow is paired with the post-join flow (`JoinRibbonView`) — see [`join-ribbon.md`](join-ribbon.md).
- Per-event customizations (intervals, custom title) live in `ReminderOverrideStore` and `EventAttributeOverrideStore`.
