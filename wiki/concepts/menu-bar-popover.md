# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/App.swift, Bubo/Views/MenuBarView.swift, Bubo/Views/Components/, Bubo/Services/ReminderService.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/App.swift`) declares a `MenuBarExtra` scene with the owl SVG icon plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Views/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, `SmartActionsBar`.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:4–13`) so the icon only repaints when count, skin, or bucket actually changes. Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:45`) — there is no SVG asset.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` surfaces the optimizer's current `shadowProposal` and a small set of contextual actions ranked by `QuickActionRanker` (in `Optimizer/Intents/`). One-click accept applies the proposal via `OptimizerService`.
