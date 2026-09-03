# Event pipeline

> **Kind:** architecture
> **Sources:** Bubo/Infrastructure/Apple/, Bubo/Application/Reminders/ReminderService.swift, Bubo/Infrastructure/Apple/EventKitSyncCoordinator.swift, Bubo/Infrastructure/Notifications/NotificationScheduler.swift, Bubo/Composition/AppDelegate/AppDelegate.swift
> **Last ingest:** 2026-09-02 (rev: removed the interim ghost workarounds (manual Hide-from-Bubo verbs, CalDAV server verification) — the split-store-roles fix plus wake rebuild and dead-push self-heal is the single, automatic remedy. Prior revs same day: split store roles / fresh read store)
> **Related:** [`overview.md`](overview.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md)

## End-to-end path

```
EventKit (EKEvent)
  → AppleCalendarService (Infrastructure/Apple/AppleCalendarService.swift)
      conforms to CalendarEventSource protocol
      (`Infrastructure/Apple/CalendarEventSource.swift:19`)
  → EventKitSyncCoordinator (Infrastructure/Apple/EventKitSyncCoordinator.swift)
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

`CalendarEvent` (in `Domain/Calendar/CalendarEvent.swift`) is Bubo's own value type — not `EKEvent`. The wrapper exists because:

- the app stores per-event overlays (color tag, reminder overrides, Pomodoro phase markers) that EventKit can't represent;
- the optimizer needs a `Sendable`, deterministic representation it can hash and shuffle;
- locally-created events live in SwiftData (`PersistedLocalEvent`) and must coexist with EventKit-sourced events behind a single type.

Conversion lives in `Optimizer/Models/EventConversion.swift` for the GA boundary.

## Local edits vs EventKit events

EventKit events are read-mostly. Bubo offers limited writes (create/edit) when the user picks a writable calendar; otherwise edits are stored as **overlays** in `EventAttributeOverrideStore` (color, custom name) or as **locally-authored** events in `LocalEventStore`. The merge happens in `EventKitSyncCoordinator`.

## Sync robustness: split store roles

The shared long-lived `EKEventStore` and the read path have opposite failure modes, so they are split:

- **Shared store (long-lived)** — owns `EKEventStoreChanged` delivery, `refreshSourcesIfNecessary()`, and writes (`createEvent`, `shiftEventTime`; `AppleRemindersService` shares it). `EventKitSyncCoordinator.syncNow()` never rebuilds it: rebuilding on every sync tore down the `calendard` IPC connection that delivers change pushes (the PR #588 lesson). `AppleCalendarService.rebuildStore()` has three sanctioned, rare triggers — all invisible to the user: after a TCC authorization grant (Settings connect flows), on wake from sleep (`handleWake`, +5 s — sleep is the main connection killer, so the store reconnects proactively and posts `calendarDataChanged` to re-sync), and the coordinator's dead-push self-heal below.
- **Reads (throwaway store per fetch)** — `fetchEvents` and `listCalendars` build a fresh `EKEventStore` via `AppleCalendarService.freshReadStore()` and discard it. A long-lived store whose daemon connection silently dies keeps serving the snapshot it froze on — deleted events linger for weeks and `ek.refresh()` answers from the same frozen snapshot — and this happens for every account type. A fresh store always reads the daemon's current database, so that staleness class is structurally impossible on the read path. One XPC handshake per fetch is the accepted cost (the widget pattern).

**Dead-push self-heal** (`EventKitSyncCoordinator.selfHealPushConnectionIfDead(eventsChanged:now:)`, clock-injectable): a live connection announces every database change via `EKEventStoreChanged` within seconds, so when a poll-driven fetch discovers a *changed* event set while the push channel has been silent longer than `pushSilenceThreshold` (10 min), the connection is provably dead — the coordinator calls `calendarSource.rebuildForSelfHeal()` + `triggerRemoteRefresh()` automatically. `AppleCalendarService.lastPushActivityAt` (stamped at store (re)creation and on every `EKEventStoreChanged`) is the freshness signal; `selfHealCooldown` (30 min) prevents rebuild storms; the first emission after launch never triggers it (no baseline). No UI: the fetch that detected the diff already returned correct data through the fresh read store — the heal only restores the live-update channel.

Instead of flushing a cache, `fetchAndUpdate()` (`EventKitSyncCoordinator.swift:246`) — the re-fetch driven by the post-sync cascade (`schedulePostSyncRefresh`, `:215`) — compares the freshly fetched `[CalendarEvent]` slice against `lastEmittedEvents` (`:78`) and only calls `onEventsUpdated` when something actually changed, so the 4/12/30/60s cascade doesn't churn the UI.

## Staleness watchdog

A second, independent timer (`startWatchdog()` / `watchdogTick(now:)` in `EventKitSyncCoordinator.swift`) checks once a minute whether `lastSyncDate` is older than `max(3 × syncIntervalMinutes, 15 min)` (`EventKitSyncCoordinator.isStale(lastSync:now:intervalMinutes:)`, pure/static). Its job is to catch the sync loop itself dying — a `syncTimer` lost across sleep/wake or invalidated without restart — which no per-sync error path can report. On a stale detection it heals first (re-arms the sync timer, runs `syncNow()`); a successful refresh clears the flag in the same turn, so the observable `isStale` property only stays `true` when the retry could not refresh (e.g. access revoked mid-flight). `ReminderService.isStale` proxies it to the UI. Never-synced is not stale — that state is already covered by `syncError` and the permission banners.

Consumers: the popover status slot (`SyncStaleBannerRow` — clickable, retries via `ReminderService.syncNow()`), the menu-bar icon failure mark (`SyncHealthEvaluator.menuBarWarning`, see [`../concepts/menu-bar-popover.md`](../concepts/menu-bar-popover.md)), and a warning row in Settings → General → Status. Note the honest limitation: EventKit exposes no per-account sync errors to third-party apps, so an upstream account failing in Calendar.app (the Apple-Calendar-⚠️ case) is invisible to Bubo — the watchdog covers Bubo's own pipeline only.

## Recurrence

Recurring events are expanded by `RecurrenceExpander` (`Domain/Recurrence/RecurrenceExpander.swift`). Individual occurrences that the user "deleted" are kept as tombstones in `ExcludedOccurrenceStore` (`Infrastructure/Persistence/ExcludedOccurrenceStore.swift`) so a single skip doesn't kill the series.

## Alert path

Per-event alert timers are scheduled by `NotificationScheduler` (`Infrastructure/Notifications/NotificationScheduler.swift`) based on `ReminderSettings.reminderIntervals` and per-event overrides from `ReminderOverrideStore`. When a timer fires:

1. A local `UserNotifications` banner is posted (fallback).
2. If `ReminderSettings.showFullScreenAlert` is on, the scheduler posts `Notification.Name.showFullScreenAlert`. `AppDelegate` observes it and presents `FullScreenAlertView` on every active screen. See [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md).
