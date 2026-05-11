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
3. When a trigger fires and `ReminderSettings.showFullScreenAlert` is on (gate at `NotificationScheduler.swift:184`), the scheduler posts `Notification.Name.showFullScreenAlert` (`NotificationScheduler.swift:332`, declared at `:360`).
4. `AppDelegate` observes that name (`AppDelegate.swift:60`), enumerates `NSScreen.screens`, and creates a borderless `NSWindow` per screen at takeover level.
5. Each window hosts `FullScreenAlertView` with the countdown, title, and join/dismiss actions.
6. A small `UserNotifications` banner is also posted as a fallback in case the windowing path fails.

## Dismissal

The alert dismisses on join, on snooze, or when the meeting begins. Snooze posts a `.snoozeReminder` notification consumed by `NotificationScheduler` to re-arm with the chosen offset.

## Wallpaper

The alert background is a `WallpaperDefinition` (`Models/Domain/WallpaperDefinition.swift`) chosen by the user in `AppearanceTabView`. Stock wallpapers ship under `Resources/`.

## Cross-references

- The pre-meeting flow is paired with the post-join flow (`JoinRibbonView`) — see [`join-ribbon.md`](join-ribbon.md).
- Per-event customizations (intervals, custom title) live in `ReminderOverrideStore` and `EventAttributeOverrideStore`.
