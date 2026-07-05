# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/MenuBar/MenuBarScreenModel.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-07-05 (rev: PR #584 R5 — header subtitle is now execution-first («Now: … · until … · next in …»); today's `DaySectionHeader` summary line is empty (count/meta moved to other days only); `WorkingHoursBoundaryRow` renders on today only, not every future day; `FreeSlotRow` durations ≥ 2 h round to a half-hour «~N½ h» label. R4 — the backlog fullscreen's `SmartActions`/`BacklogSmartActionsRow` chip row is deleted; see [`../modules/views.md`](../modules/views.md). PR #586 — `capacityForecast` (Plan chip) drops `workingDays`; verdict reads the clock only, UX_AUDIT F10 resolved)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:18`, `@main` on `:17`) declares a `MenuBarExtra` scene (`:316`) with a Core-Graphics owl glyph (`:45`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, the `planVerbChip` action rail (`MenuBarView+MainContent.swift:305`).
- The standalone `focusSummaryRow` pill strip (today / tasks / free-slots) was removed in PR #553. Those numbers are now surfaced through the existing day-section header subtitle stream (`DaySectionHeader.meta`), which already renders per-day context — duplicating them in a top chrome band was redundant.

## Popover header subtitle (REDESIGN.md R5)

`MenuBarScreenModel.headerSubtitle` (`MenuBarScreenModel.swift:354`) is execution-first: when an event is currently in progress it leads with `Now: <title> · until <end time><next suffix>`, trimming titles over 24 chars. Otherwise it falls back to the count verdict as before (`N events · next in …`, `All N done`, `No events today`).

Below the header, today's own `DaySectionHeader` (`Components/Event/DaySectionView.swift`) renders an **empty** summary line — its old «9–22 · 0 events» duplicated the popover header one band above (`summaryString` returns `""` when `isToday`). Other days still show `count + meta`. `WorkingHoursBoundaryRow` (start/end) now renders **only on today's section** (`MenuBarView+DayGroup.swift`) instead of every future day — one global rule stated once, with today keeping the interactive drag/step handles.

`FreeSlotRow.durationLabel` rounds durations ≥ 2 h to the nearest half hour with a `~` prefix (e.g. `~11½ h`); durations under 2 h stay exact minutes. The exact time range still renders alongside the label.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:5–14`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:206`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:45`) — there is no SVG asset. The working-hours fallback for the bucket calc is `9` / `18` (`App.swift:199–200`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` was deleted in REDESIGN.md R3 (PR #582) — its `shadowProposal` one-click-accept chip and `QuickActionRanker` ranked actions duplicated the Unscheduled shelf one band below. The action rail is now a single adaptive **Plan** chip (`planVerbChip`, `MenuBarView+MainContent.swift:305`) built from `BacklogLogic.capacityForecast`: `.fits` → quiet "Plan", `.over` → warning-tinted "Plan · N over", `.afterHours` → quiet "Plan · N queued". Since PR #586 (UX_AUDIT F10, resolved), this call no longer passes `workingDays` — the verdict reads working-hours clock time only, so an off-day with time left still reads `.fits`/`.afterHours` off actual minutes rather than day-of-week; `workingDays` remains an auto-placement rule for the GA and "Copy availability". Tapping it (`openPlanner()`, `:347`) opens `MenuBarPaletteContext` — the palette is now the single home for `Schedule tasks`, `Deadline mode`, and focus-verb presets. The equivalent fullscreen-backlog chip row (`SmartActions`, `BacklogSmartActionsRow`) was itself deleted in REDESIGN.md R4 (PR #584) — no screen mounts a `SmartActions`-family row anymore; see [`../modules/views.md`](../modules/views.md).

⇧⌘N previously opened an inline quick-capture popover anchored on `SmartActionsBar`'s Backlog chip (`MenuBarScreenModel.showingQuickCapture`, now removed). It now opens the unified Quick Add popover anchored on the footer's «Add» button — the same target as ⌘N (`MenuBarScreenModel.showingQuickAdd`, `MenuBarView+Lifecycle.swift:83`).
