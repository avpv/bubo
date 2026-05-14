# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+AutoDefer.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Timeline.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Strings.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventActions.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Permissions.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Focus.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/Components/Banner/MorningBriefBanner.swift, Bubo/Presentation/Views/Components/Common/OptimizerRulesStrip.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-05-14 (PR #531)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:17`) declares a `MenuBarExtra` scene (`:315`) with a Core-Graphics owl glyph (`:44`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, `SmartActionsBar`, `OptimizerRulesStrip` (rules chip strip, PR #531), `MorningBriefBanner` (E1 overnight-work receipt, PR #531).

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:4–13`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:205`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:44`) — there is no SVG asset. The working-hours fallback for the bucket calc is the literal `9…18` (`App.swift:198–199`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` surfaces the optimizer's current `shadowProposal` and a small set of contextual actions ranked by `QuickActionRanker` (in `Application/Intents/`). One-click accept applies the proposal via `OptimizerService`.

## Optimizer rules strip (PR #531)

`OptimizerRulesStrip` sits permanently below the popover header in `+MainContent.mainContent`. It renders a scrollable chip row with every active optimizer rule: working-hours window, working-days set, peak-energy hours, locked and excluded event counts, and the `BacklogLogic.CapacityForecast` verdict. The capacity forecast is computed via `optimizerRulesCapacityForecast` (a helper on `MenuBarView+MainContent`) from `backlog.pending.reduce(0){$0+$1.durationMinutes}` and the current working-hours/days settings. Tap on a chip calls the `onEdit` closure, which routes to Settings > Optimizer via `openSettings()`.

## Morning Brief (E1, PR #531)

The Morning Brief is a persistent banner (`MorningBriefBanner`) that surfaces the overnight AutoDefer report the first time the popover opens on a new calendar day.

**Gate:** `MenuBarView.shouldShowMorningBriefBanner` — returns `true` when `morningBriefDay == dayKey(for: Date())` AND `morningBriefDismissedDay != dayKey(for: Date())`.

**Wire-up:** `runAutoDeferIfNeeded` (in `+AutoDefer`) stamps three `@AppStorage` keys after every AutoDefer pass:
- `BuboMorningBriefDay` — ISO day key the brief was generated for.
- `BuboMorningBriefDeferred` — number of overdue tasks moved forward (0 is valid — "Plan refreshed" still shows on quiet days).
- `BuboMorningBriefDismissedDay` — ISO day the user dismissed the banner; set by `dismissMorningBriefForToday()`.

**Placement:** Rendered in `+MainContent.mainContent` between `OptimizerRulesStrip` and the end-of-day banner block. The `onShowDetails` callback navigates to `.backlog` when `morningBriefDeferred > 0`.
