# Module: Views

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/
> **Last ingest:** 2026-05-12 (rev: Common/ViewModels/Optimizer subfolder rename + BuboTests)
> **Related:** [`../concepts/menu-bar-popover.md`](../concepts/menu-bar-popover.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/design-principles.md`](../concepts/design-principles.md), [`skins.md`](skins.md)

## Layout

```
Presentation/Views/
├── (top-level)         # Major screens (MenuBar/, Timer/, EventDetail, design tokens)
├── Backlog/            # Full-screen backlog view + extensions
├── CommandPalette/     # CommandPalette + extensions (moved 2026-05-12 from Common/)
├── Components/         # ~50 reusable widgets
├── DesignSystem/       # DS namespace + extensions
├── Event/              # Add/edit event surfaces
├── FullScreenAlert/    # Pre-meeting takeover (moved 2026-05-12 from Common/)
├── MenuBar/            # Menu-bar popover root
├── QuickCapture/       # Global-hotkey overlay
├── Settings/           # Settings window tabs + Settings ViewModels (moved 2026-05-12 from Presentation/ViewModels/)
└── Timer/              # Pomodoro / event timer
```

## Top-level screens

| File | Type+line | Lines | Role |
|---|---|---:|---|
| `MenuBar/MenuBarView.swift` | `struct MenuBarView` (`:3`) | 2400 | Popover root. Orchestrates timeline, day navigation, day-rollover timer, initial sync status, toast state, scroll position. Three logic clusters live in sibling extension files (`+AutoDefer`, `+RollForward`, `+Pomodoro`). Nested types extracted to file scope: `MenuBarNavigation`, `MenuBarPaletteContext`, `MenuBarDayListItem`. Permission banners + settings button live in `Presentation/Views/Components/`; preference keys in `Presentation/Views/MenuBar/MenuBarPreferenceKeys.swift` |
| `MenuBarNavigation.swift` | `enum MenuBarNavigation: Equatable` (`:9`) | 43 | 8-state navigation machine for the popover. Equality compares by event/task id |
| `MenuBarPaletteContext.swift` | `struct MenuBarPaletteContext: Equatable` (`:9`) | 21 | Seed-data carrier for the command palette overlay; nil on `MenuBarView.paletteContext` = hidden |
| `MenuBarDayListItem.swift` | `enum MenuBarDayListItem: Identifiable` (`:9`) | 30 | Row kind for the day list: event / free-slot / ghost / nowMarker |
| `SettingsView.swift` | `struct SettingsView` (`:4`) | 98 | Settings window with sidebar pane selector: General, Appearance, Calendars, Reminders, World Clock, Optimizer, Assistant |
| `EventDetailView.swift` | `struct EventDetailView` (`:3`) | 630 | Event detail with metadata, Pomodoro badges, Focus-Filters tip for local/Pomodoro events, prep-scratchpad auto-expand, reschedule/extend menu actions |
| `Event/AddEventView.swift` | `struct AddEventView` (`:4`) | 652 | Event-creation form (title, date, duration, location, reminders, recurrence, Pomodoro). Two clusters live in sibling files: `+FindBestTime` and `+Pomodoro` |
| `EditTaskView.swift` | `struct EditTaskView` (`:23`) | 817 | Full-screen task editor in nav stack. Sections for title / schedule / context / options. **Explicit Save** (not autosave) — matches event-editor model |
| `NewTaskView.swift` | `struct NewTaskView` (`:17`) | 581 | Compact task creation. Sits between `QuickCaptureView` (minimal) and `EditTaskView` (full). Collapsed "More options" |
| `QuickCaptureView.swift` | `struct QuickCaptureView` (`:12`) | 121 | One-line global-hotkey overlay. Return → submit to backlog. Shift+Return → open `NewTaskView`. Esc → cancel without saving |
| `FullScreenAlert/FullScreenAlertView.swift` | `struct FullScreenAlertView` (`:3`) | 358 | Pre-meeting takeover. Live countdown, Join/Dismiss, optional next-event hint, snooze menu, skin-tinted overlay. Moved 2026-05-12 from `Views/Common/` to its own folder |
| `JoinRibbonView.swift` | `struct JoinRibbonView` (`:16`) | 92 | Post-join ribbon. Live countdown to start, meeting name, Re-alert action. Auto-dismisses at `startDate` |
| `TimerScreenView.swift` | `struct TimerScreenView` (`:3`) | 694 | Pomodoro/event timer. Live countdown ring. **Scrub gesture** adjusts `endDate`. **Pause gesture** shifts start+end. Wallpaper support. Pinned state |
| `Backlog/BacklogFullscreenView.swift` | `struct BacklogFullscreenView` (`:36`) | 952 | Full-popover task list. Inline editing, drag-reorder, urgency filter, smart-sort, hotkeys 1–9 for completion, optimizer presets, schedule/deadline actions. Three logic clusters in sibling files: `+BulkActions`, `+Reorder`, `+Actions`. `BacklogScrollOffsetKey: PreferenceKey` lives in its own file |
| `BacklogScrollOffsetKey.swift` | `struct BacklogScrollOffsetKey: PreferenceKey` (`:14`) | 18 | Publishes the task list's scroll offset to its parent for sticky-collapse of the filter band |
| `CommandPalette/CommandPalette.swift` | `struct CommandPalette` (`:14`) | 784 | Smart suggestion palette. AI intent composition, event/task search, optimization presets, **dry-run preview**, "power mode" for advanced users. Three clusters in sibling files: `+PowerMode`, `+Status`, `+Actions`. Moved 2026-05-12 from `Views/Common/` to its own folder |
| `DesignSystem.swift` + 6 siblings | `enum DS` (`:20`) | 530 + 722 | The 1228-line catalog was split across `DS+Layout` (Spacing, Density, Hero, Popover, Grid, SettingsWindow, EmptyState), `DS+Typography`, `DS+Sizes` (Component sizes, Border, Opacity), `DS+Visual` (Shadows, Elevation, Physics, Animation), `DS+Colors` (Semantic, Materials, EventColorTag, Urgency, Countdown), `DS+Formatting` (SnoozeOption, Ordinal, Time, Shared formatters). `DesignSystem.swift` itself now keeps only the `enum DS` namespace + the `Haptics` enum + the View / Text / EnvironmentValues extensions that depend on DS tokens. Call sites unchanged (`DS.Spacing.sm`, `DS.Colors.surfacePrimary`, …). |
| `BuboSkin.swift` (relocated) | `struct SkinBackgroundLayer` (`:5`) | 286 | Moved 2026-05-12 to `Presentation/Skins/BuboSkin.swift` — see [`skins.md`](skins.md) |

## Settings (`Presentation/Views/Settings/`)

| Tab | File | Type+line | Lines | Role |
|---|---|---|---:|---|
| General | `GeneralTabView.swift` | `struct GeneralTabView` (`:454`) | 575 | General prefs — badge mode, theme/skin preview cards (plus 6 sub-view structs in same file: `ThemeColorPreview :5`, `SkinPreviewCard :30`, `CustomSkinsSection :108`, `BackgroundPhotoSection :205`, `WallpaperSectionView :336`, `CloudSyncStatusSection :396`) |
| Appearance | `AppearanceTabView.swift` | `struct AppearanceTabView` (`:3`) | 50 | Skin grid (`LazyVGrid`), custom skins, wallpaper picker, background photo |
| Calendars | `CalendarsTabView.swift` | `struct CalendarsTabView` (`:3`) | 179 | Calendar access toggle + calendar selection. Refreshes auth on appear; auto-syncs on permission grant; rebuilds `EKEventStore` |
| Apple Reminders | `AppleRemindersTabView.swift` | `struct AppleRemindersTabView` (`:3`) | 422 | Sync toggle, list selection, import/export, schedule alarms. Auto-syncs on permission grant |
| Reminders (notifications) | `RemindersTabView.swift` | `struct RemindersTabView` (`:3`) | 64 | Reminder interval list, stepper-to-add, full-screen vs system-notification toggle |
| Optimizer | `OptimizerTabView.swift` | `struct OptimizerTabView` (`:5`) | 155 | Working hours (0–23), working days, default task duration `[15, 30, 60, 90]` min |
| AI | `AITabView.swift` | `struct AITabView` (`:5`) | 229 | Agent mode picker (built-in proxy vs own API key), key input, usage stats, privacy disclosure |
| Assistant | `AssistantTabView.swift` | `struct AssistantTabView` (`:10`) | 256 | Backlog cleanup nudge for stale tasks + AI mode/key/usage/privacy. Note: schedule settings live in the Optimizer tab now |
| World Clock | `WorldClockTabView.swift` | `struct WorldClockTabView` (`:3`) | 178 | Enable toggle, city search/filter, selected list with timezone IDs, drag-reorder |
| Container | `SettingsPlatter.swift` | `struct SettingsPlatter` (`:3`) | 35 | Reusable settings card with optional title; skin-aware typography and platter styling |

## Components (`Presentation/Views/Components/`)

44 SwiftUI components. All headers read directly in passes 7 and 13. Grouped by role; line numbers cite the main type declaration.

### Layout (4)
- `FlowLayout` (`FlowLayout.swift:7`) — `struct FlowLayout: Layout`
- `DaySectionView` — `DaySectionHeader<Trailing: View>` (`:4`)
- `AppBackgroundLayer` (`:3`) — layered backgrounds (wallpaper + custom photo + skin + surface tint)
- `WallpaperBackgroundLayer` (`:5`) — wallpaper with parallax offset and overscan. Supports solid color, gradient, pattern, live

### Event/task rows (5)
- `EventRowView` (`:3`)
- `BacklogTaskRow` (`:20`)
- `GhostEventRow` (`:14`)
- `FreeSlotRow` (`:12`) — first-class row inserted between events; drag-drop fill-slot handling
- `ContextualActionRow` (`:16`) — single action row with icon, verb, optional subtext, async run/discover handling

### Backlog (5)
- `BacklogHeader` (`:47`) — mode-aware (inline / fullscreen) with ring + count + sort toggle + capacity verdict
- `BacklogCapacityRing` (`:11`) — small ring visualising remaining workday minutes vs backlog duration
- `BacklogProjectPicker` (`:42`, `@MainActor`) — project switcher pill: local projects + Reminders lists + inline creation
- `BacklogTombstones` (`:28`) — completed-today and frozen tasks with expand/collapse and restore
- `TaskListExpansion` (`:23`, `enum`) — two-state (collapsed / compact) disclosure of Tasks card

### Pickers (11)
- `DateTimePickerPills` (`:3`) — horizontal pill pair (date + time) with popovers
- `DurationPicker` (`:15`) — preset menu + stepper; label is clickable for direct typing
- `RecurrencePickerView` (`:4`)
- `EmojiPickerView` (`:4`) — Telegram-style popover with category tabs and search
- `SegmentedPillPicker` (`:5`) — horizontal scrollable pill row, generic options
- `PeakEnergyHoursPicker` (`:19`) — 24-chip toggle grid, hours 0–23
- `WorkingDaysPicker` (`:22`) — seven-chip Mon–Sun checkbox row
- `WorkingHoursBoundaryRow` (`:27`) — draggable boundary divider for working-hours start/end with step buttons and real-time reshape
- `SlotPickerPopover` — `enum SlotPickerCommitItem` (`:14`) for queued placements (existing task or new creation)
- `DateSuggestionsPopover` (`:3`) — quick suggestions + fallback to graphical calendar picker
- `DeadlinePickerPopover` (`:14`) — `DatePicker` in platter chrome with Save/Cancel/Clear

### Popovers (3)
- `SlotAlternativesPopover` (`:13`) — top-N GA-ranked slot candidates for a backlog task
- `SmartActions` (`:30`) — chip row absorbing four legacy optimizer entry points; forecasts capacity + ranks actions
- `SmartActionsBar` (`:13`)

### Status / feedback (6)
- `StatusBannerView` — `StatusBanner` (`:3`), color-driven, used for network status
- `ToastView` — `ToastMessage` (`:4`), `ToastOverlay: View` (`:69`)
- `EndOfDayBanner` (`:17`) — quiet end-of-day prompt with one-tap carry-to-tomorrow
- `EnergyCheckInBanner` (`:9`) — one-tap rating (1–5), feeds the personal energy curve
- `RollForwardBanner` (`:13`) — end-of-workday nudge with unified undo
- `NowNextLine` (`:16`) — single-line status with current and next event + overdue chip

### Utility (9)
- `Chip` — `enum ChipVariant` (`:22`) defines visual roles (prominent / quiet / selected / unselected / status)
- `ColorDotButton` (`:7`) — reusable color dot with hover/focus/animation for event filtering
- `FreeSlotDotButton` (`:31`) — tri-state filter: show-all / free-slots-only / hide-free
- `OwlIcon` (`:3`) — `Canvas`-drawn owl with bounce animation; respects Reduce Motion
- `MarkdownText` (`:6`)
- `FormattableTextView` (`:9`) — multi-line text view with Markdown formatting items in context menu; `NSViewRepresentable` bridge
- `InlineTimePicker` (`:10`) — clickable time label opens flat dropdown of 30-min slots
- `WorldClockStripView` — `struct WorldClockCity` (`:5`), Codable, ~50+ global cities
- `DisintegrationEffect` — `DisintegrationModifier` (`:20`), Thanos-style particle disintegration on state change

Additional components extracted from `MenuBarView`:
- `OpenSettingsButton` (`Components/OpenSettingsButton.swift`) — gear button that closes the popover and opens the Settings window.
- `PermissionBannerSpec`, `PermissionBannerLabel`, `PermissionBannersCarousel`, `PermissionBannerPageDots` (`Components/PermissionBanners.swift`) — single-pill or paged-carousel permission banner under the popover header.
- `EventColorTag.color` SwiftUI mapping (`Components/EventColorTag+Color.swift`) — kept out of the domain model so `Domain/CalendarEvent.swift` doesn't need `import SwiftUI`.
- `LoadMoreDaysButton` (`Components/LoadMoreDaysButton.swift`) — quiet full-width footer below the timeline that fires the host's «extend horizon by one week» closure. PR 1 of `BODY-SPLIT-PLAN.md`.

Re-list: `ls Bubo/Presentation/Views/Components/*.swift | wc -l`.

## Size hotspots

Top SwiftUI files by line count.

| File | Lines | Top-level structure (verified by `grep -n '^struct\|^private struct'`) |
|---|---:|---|
| `MenuBar/MenuBarView.swift` | 2400 | Body + most subview helpers. Three logic clusters split out 2026-05-12: `MenuBarView+AutoDefer.swift` (162, midnight rollover + EOD banner), `MenuBarView+RollForward.swift` (180, J-Recover + focus-slot fill + overdue reschedule), `MenuBarView+Pomodoro.swift` (206, convertEventToPomodoro + clone-as-draft + ripple-shift + slot Pomodoro). State surface (~30 `@State` fields), notable: `navigation: MenuBarNavigation` (state-machine enum), `dayRolloverTimer`, `everyMinuteTimer`, `initialSyncTimeoutFired` + `initialSyncDataArrived`, `extraDaysShown` capped at `extraDaysCap = 84`, `colorFilter` + `freeSlotFilter`, `backlogCoordinator`, `paletteContext`. `@State`/`@AppStorage` on `dayRolloverTimer`, `rollForwardDismissedDay`, `eodDismissedDay` is internal (was `private`) so siblings can mutate. |
| `Backlog/BacklogFullscreenView.swift` | 952 | Body + computed properties + subview helpers + filter chrome. Three logic clusters split out 2026-05-12: `+BulkActions.swift` (131, multi-select schedule/defer/freeze/delete + tombstone undo), `+Reorder.swift` (132, up/down/edge moves + drag-reorder drop), `+Actions.swift` (147, per-task CRUD + inline-add). All `@State`/`@FocusState`/`@Environment` wrappers are internal so siblings can read/write. |
| `CommandPalette/CommandPalette.swift` | 784 | NL intent / quick action search. Three clusters split out 2026-05-12: `+PowerMode.swift` (216, progressive-disclosure composer for OptimizationRequest), `+Status.swift` (133, status/applied/failed result surfaces), `+Actions.swift` (172, handleSubmit/runRequest + keyboard shortcuts). |
| `Components/Backlog/BacklogTaskRow.swift` | 730 | Single-row component. `BacklogTaskRow+Subviews.swift` (601) holds drag payload + checkbox/content/controls/background/focus-ring/scheduled-chip helpers; `OverduePulseDot.swift` (25) lifted to its own file. |
| `Components/Event/EventRowView.swift` | 721 | Single-row component. Three clusters split out 2026-05-12: `+Title.swift` (102, inline rename gate + commit/cancel), `+DragReschedule.swift` (134, vertical drag with minute snapping + preview badge), `+HoverActions.swift` (169, snooze/complete/disintegration-delete/reminder menu). |
| `Event/AddEventView.swift` | 652 | Event-creation form. Two clusters split out 2026-05-12: `+FindBestTime.swift` (117, optimizer-driven slot suggestion + helpers), `+Pomodoro.swift` (347, toggle + section + timeline preview + recurrence-rule builder). |

Treat these as flagged for further decomposition only if needed — the 2026-05-12 logic split brought every "mega-file" below ~1000 lines except `MenuBarView.swift` at 2400. The deferred PRs in `BODY-SPLIT-PLAN.md` (mainContent extraction) are still the most leveraged remaining split for MenuBarView and Backlog.

## Conventions

- Views consume `@Observable` services directly — no `ViewModel` for most screens. `Presentation/Views/Settings/` is used only where state is non-trivial (settings, cloud sync). See [`viewmodels.md`](viewmodels.md).
- All sizes/colors/fonts/easing come from `DesignSystem.swift` (the `DS` namespace). Magic numbers in feature views are a smell.
- Skin-themable properties go through `BuboSkin.swift`. Skins can change mood (accent, tint, button weight) but not layout/materials/semantics — see [`../concepts/skins-system.md`](../concepts/skins-system.md).
- Design rules in `docs/design/PRINCIPLES.md` are normative for view code — see [`../concepts/design-principles.md`](../concepts/design-principles.md).
