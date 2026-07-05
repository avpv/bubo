# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/MenuBar/MenuBarScreenModel.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-07-05 (rev: PR #582 — action rail collapses to one adaptive «Plan» chip, `SmartActionsBar` deleted; dropped six dead `Sources` entries for extension files removed by an earlier untracked refactor: `+AutoDefer`, `+Timeline`, `+Strings`, `+EventActions`, `+Permissions`, `+Focus`)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:18`, `@main` on `:17`) declares a `MenuBarExtra` scene (`:316`) with a Core-Graphics owl glyph (`:45`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, the `planVerbChip` action rail (`MenuBarView+MainContent.swift:305`).
- The standalone `focusSummaryRow` pill strip (today / tasks / free-slots) was removed in PR #553. Those numbers are now surfaced through the existing day-section header subtitle stream (`DaySectionHeader.meta`), which already renders per-day context — duplicating them in a top chrome band was redundant.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:5–14`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:206`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:45`) — there is no SVG asset. The working-hours fallback for the bucket calc is `9` / `18` (`App.swift:199–200`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` was deleted in REDESIGN.md R3 (PR #582) — its `shadowProposal` one-click-accept chip and `QuickActionRanker` ranked actions duplicated the Unscheduled shelf one band below. The action rail is now a single adaptive **Plan** chip (`planVerbChip`, `MenuBarView+MainContent.swift:305`) built from `BacklogLogic.capacityForecast`: `.fits` → quiet "Plan", `.over` → warning-tinted "Plan · N over", `.afterHours` → quiet "Plan · N queued". Tapping it (`openPlanner()`, `:347`) opens `MenuBarPaletteContext` — the palette is now the single home for `Schedule tasks`, `Deadline mode`, and focus-verb presets. `shadowProposal` and `QuickActionRanker` still drive the equivalent `SmartActions` chip row inside the backlog fullscreen screen (`Components/Backlog/SmartActions.swift`, `BacklogSmartActionsRow.swift`) — only the main-screen rail lost the one-click-accept path.

⇧⌘N previously opened an inline quick-capture popover anchored on `SmartActionsBar`'s Backlog chip (`MenuBarScreenModel.showingQuickCapture`, now removed). It now opens the unified Quick Add popover anchored on the footer's «Add» button — the same target as ⌘N (`MenuBarScreenModel.showingQuickAdd`, `MenuBarView+Lifecycle.swift:83`).
