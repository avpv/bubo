# Reminders — Layer Boundaries

The "Reminders" feature is split across three peer layers. This README
records what each layer owns so a new contributor can place a change
without grepping for the answer.

## Domain — `Sources/BuboDomain/Reminders`

Pure value types and policy. **No** `import EventKit`, `AppKit`,
`SwiftUI`, `CloudKit`, or `SwiftData`. Only `Foundation`.

Owns:
- `ReminderSettings` and any future reminder-related value types.
- Policy decisions expressed as plain functions/structs (e.g. lead-time
  intervals, badge-count rules) that read settings and return data.

Does **not** own:
- Persistence, EventKit calls, notification delivery, UI state, sync
  timers.

## Application — `Bubo/Application/Reminders`

Orchestration. Wires the domain policy to infrastructure adapters and
exposes a `@MainActor`-friendly surface for the UI. Imports
`Foundation`, `SwiftData`, `os` — **no platform UI frameworks**, **no
EventKit**, **no AppKit**.

Owns:
- `ReminderService` — the orchestrator the views read from. Holds
  in-memory event collections, exposes computed view properties
  (`allEvents`, `eventsByDay`, `badgeCount`), and wires the four
  sub-services together.
- `RemindersSyncService` (+`Writeback`) — bridges the backlog into
  Apple Reminders and back, including completion/edit/schedule/remove
  propagation and self-write suppression.

Talks to infrastructure exclusively through protocols
(`LocalEventStoring`, `ExcludedOccurrenceStoring`, `CalendarEventSource`,
etc.), so tests can substitute in-memory fakes.

## Infrastructure — split by adapter, not by feature

Adapters that actually touch EventKit, UserNotifications, the file
system, and SwiftData. This is the **only** layer allowed to
`import EventKit` / `import UserNotifications`.

The former `Bubo/Infrastructure/Reminders/` directory was misleading
(its name collided with Apple Reminders). It was split by what each
file talks to:

- `Bubo/Infrastructure/Apple/EventKitSyncCoordinator.swift` — periodic
  EventKit sync, calendar-data observer, on-disk cache, post-sync
  follow-ups. Lives next to the other EventKit wrappers.
- `Bubo/Infrastructure/Notifications/NotificationScheduler.swift` —
  per-event `Timer` scheduling, fired-key dedup,
  `UNNotificationCenter` delivery. Lives in its own
  `Notifications/` directory because it has nothing to do with
  Apple Reminders.

## Rule of Thumb

| Concern | Layer |
| --- | --- |
| "What does the user want?" (settings, policy) | Domain |
| "Apply the policy to the current world" | Application |
| "Talk to EventKit / disk / OS" | Infrastructure |

If a change forces a `Foundation`-only file to import a platform
framework, the change belongs one layer down.
