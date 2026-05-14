# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+AutoDefer.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Timeline.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Strings.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventActions.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Permissions.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Focus.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-05-14 (rev: PR #547 — Command Bar replaces `PopoverHeader` at top of `mainContent`; `NowNextLine` removed; layout order updated)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:18`, `@main` on `:17`) declares a `MenuBarExtra` scene (`:316`) with a Core-Graphics owl glyph (`:45`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `SmartActionsBar`, `inlineStatusRow` (single-line network/sync/cache status).

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:5–14`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:206`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:45`) — there is no SVG asset. The working-hours fallback for the bucket calc is `9` / `18` (`App.swift:199–200`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Main content layout

`MenuBarView+MainContent.swift:128` (`mainContent`) stacks sub-views in this order:

1. **Optimizer Command Bar** — full-width button ("What should we optimize?", sparkles icon, ⌘K badge). Tapping sets `paletteContext = MenuBarPaletteContext()` to open the command palette. Added in PR #547 as the command-first entry point; replaces the old `PopoverHeader` title block at the top.
2. **SmartActionsBar** — chip row of ranked quick actions (shown only when `optimizerService.backlogService` is non-nil).
3. **Date header** — inline `HStack` with `headerTitle` / `headerSubtitle` labels and `dayNavCluster` (day-navigation arrows, shown when `filteredEventsByDay.count > 1`). Replaces the former `PopoverHeader` component at this position.
4. **`inlineStatusRow`** — single quiet line for the highest-priority system issue (no network, sync error, cached data).
5. **`WorldClockStripView`** — shown only when `settings.worldClockCityIDs` is non-empty.
6. **`ColorFilterBar`** — shown only when `reminderService.nonDisintegratingEventCount > 0`.
7. **Events** — scrollable timeline (day-sections with event/free-slot/ghost rows).

## Quick actions

`SmartActionsBar` surfaces the optimizer's current `shadowProposal` and a small set of contextual actions ranked by `QuickActionRanker` (in `Application/Intents/`). One-click accept applies the proposal via `OptimizerService`. The Optimizer Command Bar above it is the primary ⌘K entry point for NL intent composition.
