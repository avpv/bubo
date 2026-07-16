# Menu bar popover

> **Kind:** concept
> **Sources:** Bubo/Composition/App/App.swift, Bubo/Presentation/Views/MenuBar/MenuBarView.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+RollForward.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Pomodoro.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+BacklogDrop.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+NavigationRoutes.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+Lifecycle.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift, Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift, Bubo/Presentation/Views/MenuBar/MenuBarScreenModel.swift, Bubo/Presentation/Views/Components/, Bubo/Application/Reminders/ReminderService.swift
> **Last ingest:** 2026-07-16 (rev: PR #595 — menu bar icon no longer follows the active skin's accent colour, always a template image now; `App.swift` line refs re-based (file shrank 357→320 lines). Prior rev: wiki-ingest for PR #593 — today's `DaySectionHeader` title is no longer accent-tinted (DESIGN_REVIEW R1: primary text on every day, not just non-today ones); `DaySectionHeader`'s sticky background switched from `.regularMaterial` to `skinBarBackground`, matching the popover header/footer bar treatment. Prior rev: PR #590 — per-day working-hours overrides: boundary rows are now-anchored and read/write today's override via `OptimizerService.workingHours(on:)`/`setWorkingHours(on:)`; the Plan chip's `capacityForecast` call also resolves today's override; today's `DaySectionHeader` title collapses to accent «Today» (no eyebrow); per-row calendar captions hide when the timeline has only one calendar (`timelineSpansMultipleCalendars`); header block is now banded (`skinBarBackground` + `SkinSeparator`). Prior rev: PR #584 R5 — header subtitle is now execution-first («Now: … · until … · next in …»); today's `DaySectionHeader` summary line is empty (count/meta moved to other days only); `FreeSlotRow` durations ≥ 2 h round to a half-hour «~N½ h» label. R4 — the backlog fullscreen's `SmartActions`/`BacklogSmartActionsRow` chip row is deleted; see [`../modules/views.md`](../modules/views.md). PR #586 — `capacityForecast` (Plan chip) drops `workingDays`; verdict reads the clock only, UX_AUDIT F10 resolved)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/views.md`](../modules/views.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## What

The menu-bar popover is Bubo's primary surface — one click on the owl icon opens the day's timeline, event list, and quick actions. No window to manage.

## How it's wired

- `BuboApp` (`Bubo/Composition/App/App.swift:17`, `@main` on `:16`) declares a `MenuBarExtra` scene (`:279`) with a Core-Graphics owl glyph (`:44`) plus a density bar (calendar-load indicator).
- The scene's content is `MenuBarView` (`Bubo/Presentation/Views/MenuBar/MenuBarView.swift`).
- `MenuBarView` reads `ReminderService.upcomingEvents` and `BacklogService.tasks` directly via `@Observable`.
- Sub-views: `DaySectionView`, `EventRowView`, `GhostEventRow` (optimizer ghost previews), `FreeSlotRow`, `NowNextLine`, the `planVerbChip` action rail (`MenuBarView+MainContent.swift:305`).
- The standalone `focusSummaryRow` pill strip (today / tasks / free-slots) was removed in PR #553. Those numbers are now surfaced through the existing day-section header subtitle stream (`DaySectionHeader.meta`), which already renders per-day context — duplicating them in a top chrome band was redundant.

## Popover header subtitle (REDESIGN.md R5)

`MenuBarScreenModel.headerSubtitle` (`MenuBarScreenModel.swift:354`) is execution-first: when an event is currently in progress it leads with `Now: <title> · until <end time><next suffix>`, trimming titles over 24 chars. Otherwise it falls back to the count verdict as before (`N events · next in …`, `All N done`, `No events today`).

Below the header, today's own `DaySectionHeader` (`Components/Event/DaySectionView.swift`) renders an **empty** summary line — its old «9–22 · 0 events» duplicated the popover header one band above (`summaryString` returns `""` when `isToday`). Other days still show `count + meta`. Today's title still collapses to the single word «Today» (no eyebrow); tomorrow keeps eyebrow «Tomorrow» + weekday-and-date title; further-out days show eyebrow = weekday, title = date only (`DaySectionView.swift:` `dayTitle`/`isToday` branch). As of PR #593 (DESIGN_REVIEW R1), the title no longer gets an accent tint on today — every day's title renders in `skin.resolvedTextPrimary`, so «Today» reads as plain text, not a signal; the eyebrow keeps its accent tint when shown. `DaySectionHeader`'s sticky background also switched from `.regularMaterial` to `skinBarBackground` (same bar treatment as the popover header and footer), so all day sections now share one chrome material product-wide.

`WorkingHoursBoundaryRow` (start/end) renders **only on today's section** (`MenuBarView+DayGroup.swift`), and each handle is now-anchored: the start row disappears once the hour has passed, the end row once the working day is over (PR #590). Both handles read and write a **per-day override** via `OptimizerService.workingHours(on:)` / `setWorkingHours(on:start:end:)` (see `../modules/services.md`) — dragging tonight's boundary is a decision about today only; tomorrow still reads the global default from Settings → Optimizer unless it too was adjusted. The «After hours» caption compares against the same per-day window.

`FreeSlotRow.durationLabel` rounds durations ≥ 2 h to the nearest half hour with a `~` prefix (e.g. `~11½ h`); durations under 2 h stay exact minutes. The exact time range still renders alongside the label.

## Density bar (J2)

The thin bar under the owl is a 0–10 density bucket — fraction of today's working window already booked. Computed and cached alongside the icon in `MenuBarIconCache` (`App.swift:5–12`) so the icon only repaints when count or bucket actually changes. Bar painted by `drawDensityBar(in:size:color:bucket:)` (`App.swift:171`). Owl glyph is rendered in Core Graphics via `BuboApp.drawOwl(in:size:color:)` (`App.swift:44`) — there is no SVG asset. The working-hours fallback for the bucket calc is `9` / `18` (`App.swift:164–165`), independent of `OptimizerService.workingHoursDefault`. As of PR #595, the icon no longer follows the active skin's accent colour — it is always a template image (black, `isTemplate = true`), left for the system to paint white-on-dark/black-on-light; the badge variant (non-template) mirrors this with an explicit `isDark` check instead of skin tinting.

## Badge

The dock-tile and status-item badge count is governed by `ReminderSettings.badgeCountMode` (off, unread reminders, today's events, etc.).

## Quick actions

`SmartActionsBar` was deleted in REDESIGN.md R3 (PR #582) — its `shadowProposal` one-click-accept chip and `QuickActionRanker` ranked actions duplicated the Unscheduled shelf one band below. The action rail is now a single adaptive **Plan** chip (`planVerbChip`, `MenuBarView+MainContent.swift:305`) built from `BacklogLogic.capacityForecast`: `.fits` → quiet "Plan", `.over` → warning-tinted "Plan · N over", `.afterHours` → quiet "Plan · N queued". Since PR #586 (UX_AUDIT F10, resolved), this call no longer passes `workingDays` — the verdict reads working-hours clock time only; `workingDays` remains an auto-placement rule for the GA and "Copy availability". Since PR #590, the call also resolves **today's per-day override** (`optimizerService.workingHours(on: screen.nowTick)` — see `../modules/services.md`) instead of the global setting directly, so the chip agrees with a boundary the user just dragged on the timeline. Tapping it (`openPlanner()`, `:347`) opens `MenuBarPaletteContext` — the palette is now the single home for `Schedule tasks`, `Deadline mode`, and focus-verb presets. The equivalent fullscreen-backlog chip row (`SmartActions`, `BacklogSmartActionsRow`) was itself deleted in REDESIGN.md R4 (PR #584) — no screen mounts a `SmartActions`-family row anymore; see [`../modules/views.md`](../modules/views.md).

Per-row calendar captions (`EventRowView.showsCalendarName`) only render when `MenuBarScreenModel.timelineSpansMultipleCalendars` is true (`MenuBarScreenModel.swift`) — with one calendar configured the caption repeated the same name down every row and crowded out the location, so it's hidden and the location gets `.layoutPriority(1)` on the meta line (PR #590).

The header block (`MenuBarView+MainContent.swift:headerBlock`) is now banded like every other popover screen — `skinBarBackground` + a trailing `SkinSeparator` — with the world clock line inside the bar and the Plan rail below it on the canvas side (PRINCIPLES §11/§12, PR #590).

⇧⌘N previously opened an inline quick-capture popover anchored on `SmartActionsBar`'s Backlog chip (`MenuBarScreenModel.showingQuickCapture`, now removed). It now opens the unified Quick Add popover anchored on the footer's «Add» button — the same target as ⌘N (`MenuBarScreenModel.showingQuickAdd`, `MenuBarView+Lifecycle.swift:83`).
