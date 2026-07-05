# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarScreenModel.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-07-05 (rev: `MenuBarView+AutoDefer`/`+EventActions` merged into `+Lifecycle`/`+EventRow`; session state moved to `MenuBarScreenModel`; Unscheduled shelf + unified Quick Add front door added; PR #580)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:18`, `@main` on `:17`) declares a `MenuBarExtra` scene (`:316`) with a Core-Graphics owl glyph (`:45`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`), which holds only 2 `@State` fields (`screen`, `backlogCoordinator`); everything else lives on `MenuBarScreenModel` (`:15`, `@Observable`) — timeline/filter derivation plus popover-session state (toasts, scroll position, quick-capture/quick-add presentation, Unscheduled-shelf and filter-bar disclosure, measured optimizer-bar bottom, day-rollover timer). See [`../modules/views.md`](../modules/views.md) for the full sibling-extension list.
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, `SmartActionsBar`, `UnscheduledShelfView`.
- The standalone `focusSummaryRow` pill strip (today / tasks / free-slots) was removed in PR #553. Those numbers are now surfaced through the existing day-section header subtitle stream (`DaySectionHeader.meta`), which already renders per-day context — duplicating them in a top chrome band was redundant.
- **Unscheduled shelf** (REDESIGN.md R1, PR #580): the event list's `leadingContent` is now `UnscheduledShelfView`, showing pending backlog tasks as the first block on the timeline canvas instead of only inside the separate Backlog screen. Collapsed to one summary line by default (`screen.unscheduledExpansion`); a row tap seeds the command palette (`MenuBarPaletteContext(seedTask:)`), a row drag targets the same `BacklogTaskDrag` payload free slots already accept.
- **Resting screen carries no strips** (REDESIGN.md R2, PR #580): the world clock moved from a permanent pill strip into one quiet line (`WorldClockInlineLine`) inside the header block; the color/free-slot filter bar (`ColorFilterBar`) now renders only when toggled via the header's filter glyph or when a filter is already active (`screen.showingFilterBar || hasActiveTimelineFilter`) — an active filter is never allowed to hide, since a silently filtered "no events" reads as a lie.
- **Unified "Add" front door** (UX_AUDIT.md F8, PR #580): the footer's primary button label changed from "Add event" to "Add" and now opens `QuickAddView` (⌘N) — one text field whose content is routed by `QuickAddParser` to a task or an event (an explicit clock time makes it an event). Commits go through `MenuBarView+MainContent`'s `handleQuickAddTask`/`handleQuickAddEvent`; ⇧↩ escapes to the detailed New Event/New Task form pre-filled via `routeQuickAddDetails`. The separate `QuickCaptureView` (⇧⌘N global hotkey) is unchanged and still task-only.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:5–14`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:206`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:45`) — there is no SVG asset. The working-hours fallback for the bucket calc is `9` / `18` (`App.swift:199–200`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` surfaces the optimizer's current `shadowProposal` and a small set of contextual actions ranked by `QuickActionRanker` (in `Application/Intents/`). One-click accept applies the proposal via `OptimizerService`.
