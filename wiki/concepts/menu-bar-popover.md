# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+AutoDefer.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Timeline.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Strings.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventActions.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Permissions.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Focus.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-06-11 (rev: permission banners carousel restored in inlineStatusRow; empty-day boundary suppression; PR #563)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:18`, `@main` on `:17`) declares a `MenuBarExtra` scene (`:316`) with a Core-Graphics owl glyph (`:45`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, `SmartActionsBar`.
- The standalone `focusSummaryRow` pill strip (today / tasks / free-slots) was removed in PR #553. Those numbers are now surfaced through the existing day-section header subtitle stream (`DaySectionHeader.meta`), which already renders per-day context — duplicating them in a top chrome band was redundant.
- `inlineStatusRow` (`MenuBarView+MainContent.swift:66`) sits below the header and shows the highest-priority issue only: offline warning first, then per-service permission banners (Calendar / Reminders), then a generic sync error. Hidden when everything is healthy. Permission banners use `PermissionBannersCarousel` (`Components/Banner/PermissionBannerRow.swift`) — a single missing permission renders as one clickable pill; both missing render as a paged horizontal carousel. Each banner deep-links to the Settings pane that fixes it via `SettingsViewModel.pendingPane`. The specs are built by `permissionBannerSpecs` (`MenuBarView+Permissions.swift:22`).
- `WorkingHoursBoundaryRow` start and end markers are suppressed on days with no items (`MenuBarView+DayGroup.swift:52`): an empty day showed two floating boundary rows with nothing between them.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:5–14`) so the icon only repaints when count, skin, or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:206`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:45`) — there is no SVG asset. The working-hours fallback for the bucket calc is `9` / `18` (`App.swift:199–200`), independent of `OptimizerService.workingHoursDefault`.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` surfaces the optimizer's current `shadowProposal` and a small set of contextual actions ranked by `QuickActionRanker` (in `Application/Intents/`). One-click accept applies the proposal via `OptimizerService`.
