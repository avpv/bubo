# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarScreenModel.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+AutoDefer.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventActions.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-06-11 (rev: `MenuBarScreenModel` extracts timeline/filter/nav state from `MenuBarView`; deleted `+Timeline`, `+Strings`, `+Permissions`, `+Focus`; PR #567)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:18`, `@main` on `:17`) declares a `MenuBarExtra` scene (`:316`) with a Core-Graphics owl glyph (`:45`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView`'s explicit `init` creates a `BacklogInteractionCoordinator` and a `MenuBarScreenModel` (`MenuBarScreenModel.swift:15`) stored as `@State var screen`.
- `MenuBarScreenModel` (`@MainActor @Observable final class`, 409 L) holds all timeline/filter/nav state: `colorFilter`, `freeSlotFilter`, `focusedDayDate`, `extraDaysShown` (84-day cap via `extraDaysCap`), `nowTick`, `navigation: MenuBarNavigation`, and `paletteContext`. It also owns sync-lifecycle flags (`hasStartedSync`, `initialSyncTimeoutFired`, `initialSyncDataArrived`), permission snapshots (`calendarHasAccess`, `remindersHasAccess`, `refreshPermissionSnapshots()`), and all pure derived computation: `filteredEventsByDay`, `timelineEventsByDay`, `timelineDays()`, interleaving, ghost placement, day-nav index, and header/empty-state strings. `MenuBarView` retains only view-machinery `@State`: `toastState`, scroll position, quick-capture flag, and the wallpaper parallax offset key.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, `SmartActionsBar`.
- The standalone `focusSummaryRow` pill strip (today / tasks / free-slots) was removed in PR #553. Those numbers are now surfaced through the existing day-section header subtitle stream (`DaySectionHeader.meta`), which already renders per-day context — duplicating them in a top chrome band was redundant.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:5–14`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:206`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:45`) — there is no SVG asset. The working-hours fallback for the bucket calc is `9` / `18` (`App.swift:199–200`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` surfaces the optimizer's current `shadowProposal` and a small set of contextual actions ranked by `QuickActionRanker` (in `Application/Intents/`). One-click accept applies the proposal via `OptimizerService`.
