# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+AutoDefer.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-05-12 (rev: MenuBarView split — AutoDefer / RollForward / Pomodoro extensions)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App.swift:17`) declares a `MenuBarExtra` scene (`:315`) with a Core-Graphics owl glyph (`:44`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, `SmartActionsBar`.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:4–13`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:205`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:44`) — there is no SVG asset. The working-hours fallback for the bucket calc is the literal `9…18` (`App.swift:198–199`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` surfaces the optimizer's current `shadowProposal` and a small set of contextual actions ranked by `QuickActionRanker` (in `Optimizer/Intents/`). One-click accept applies the proposal via `OptimizerService`.
