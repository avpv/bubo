# Module: Views

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/
> **Last ingest:** 2026-05-11
> **Related:** [`../concepts/menu-bar-popover.md`](../concepts/menu-bar-popover.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/design-principles.md`](../concepts/design-principles.md), [`skins.md`](skins.md)

## Layout

```
Presentation/Views/
├── (top-level)        # Major screens, design tokens
├── Components/        # ~50 reusable widgets
└── Settings/          # Settings window tabs
```

## Top-level screens

| File | Type+line | Lines | Role |
|---|---|---:|---|
| `MenuBarView.swift` | `struct MenuBarView` (`:3`) | 3256 | Popover root. Orchestrates timeline, day navigation, day-rollover timer, initial sync status, toast state, scroll position. Wires services and callbacks. Nested types extracted to file scope: `MenuBarNavigation`, `MenuBarPaletteContext`, `MenuBarDayListItem`. Permission banners + settings button live in `Presentation/Views/Components/`; preference keys in `Presentation/Views/MenuBarPreferenceKeys.swift` |
| `MenuBarNavigation.swift` | `enum MenuBarNavigation: Equatable` (`:9`) | 43 | 8-state navigation machine for the popover. Equality compares by event/task id |
| `MenuBarPaletteContext.swift` | `struct MenuBarPaletteContext: Equatable` (`:9`) | 21 | Seed-data carrier for the command palette overlay; nil on `MenuBarView.paletteContext` = hidden |
| `MenuBarDayListItem.swift` | `enum MenuBarDayListItem: Identifiable` (`:9`) | 30 | Row kind for the day list: event / free-slot / ghost / nowMarker |
| `SettingsView.swift` | `struct SettingsView` (`:4`) | 98 | Settings window with sidebar pane selector: General, Appearance, Calendars, Reminders, World Clock, Optimizer, Assistant |
| `EventDetailView.swift` | `struct EventDetailView` (`:3`) | 630 | Event detail with metadata, Pomodoro badges, Focus-Filters tip for local/Pomodoro events, prep-scratchpad auto-expand, reschedule/extend menu actions |
| `AddEventView.swift` | `struct AddEventView` (`:4`) | 1096 | Event-creation form (title, date, duration, location, reminders, recurrence, Pomodoro). Can prefill from an existing event for duplication |
| `EditTaskView.swift` | `struct EditTaskView` (`:23`) | 817 | Full-screen task editor in nav stack. Sections for title / schedule / context / options. **Explicit Save** (not autosave) — matches event-editor model |
| `NewTaskView.swift` | `struct NewTaskView` (`:17`) | 581 | Compact task creation. Sits between `QuickCaptureView` (minimal) and `EditTaskView` (full). Collapsed "More options" |
| `QuickCaptureView.swift` | `struct QuickCaptureView` (`:12`) | 121 | One-line global-hotkey overlay. Return → submit to backlog. Shift+Return → open `NewTaskView`. Esc → cancel without saving |
| `FullScreenAlertView.swift` | `struct FullScreenAlertView` (`:3`) | 358 | Pre-meeting takeover. Live countdown, Join/Dismiss, optional next-event hint, snooze menu, skin-tinted overlay |
| `JoinRibbonView.swift` | `struct JoinRibbonView` (`:16`) | 92 | Post-join ribbon. Live countdown to start, meeting name, Re-alert action. Auto-dismisses at `startDate` |
| `TimerScreenView.swift` | `struct TimerScreenView` (`:3`) | 694 | Pomodoro/event timer. Live countdown ring. **Scrub gesture** adjusts `endDate`. **Pause gesture** shifts start+end. Wallpaper support. Pinned state |
| `BacklogFullscreenView.swift` | `struct BacklogFullscreenView` (`:36`) | 2026 | Full-popover task list. Inline editing, drag-reorder, urgency filter, smart-sort, hotkeys 1–9 for completion, optimizer presets, schedule/deadline actions. `BacklogScrollOffsetKey: PreferenceKey` lives in its own file |
| `BacklogScrollOffsetKey.swift` | `struct BacklogScrollOffsetKey: PreferenceKey` (`:14`) | 18 | Publishes the task list's scroll offset to its parent for sticky-collapse of the filter band |
| `CommandPalette.swift` | `struct CommandPalette` (`:14`) | 1275 | Smart suggestion palette. AI intent composition, event/task search, optimization presets, **dry-run preview**, "power mode" for advanced users |
| `DesignSystem.swift` | `enum DS` (`:6`) | 1228 | Centralized design tokens — 4-pt grid spacing, density modes (`comfortable` / `compact`), typography, colors, materials. Single vertical axis for all surfaces |
| `BuboSkin.swift` | `struct SkinBackgroundLayer` (`:5`) | 286 | Renders skin-specific gradient backgrounds with blend modes (gradient or radial variants) |

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

43 SwiftUI components. All headers read directly in passes 7 and 13. Grouped by role; line numbers cite the main type declaration.

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

Re-list: `ls Bubo/Presentation/Views/Components/*.swift | wc -l`.

## Size hotspots

Top SwiftUI files by line count.

| File | Lines | Top-level structure (verified by `grep -n '^struct\|^private struct'`) |
|---|---:|---|
| `MenuBarView.swift` | 3256 | Almost the entire file is `struct MenuBarView: View` (`:3`). Sibling files in `Presentation/Views/`: `MenuBarNavigation.swift`, `MenuBarPaletteContext.swift`, `MenuBarDayListItem.swift`, `MenuBarPreferenceKeys.swift`. Permission banners + settings button live in `Presentation/Views/Components/`. State surface (~30 `@State` fields): `navigation: MenuBarNavigation` (state-machine enum with 8 cases — `list`/`detail`/`addEvent`/`editTask`/`newTask`/`timer`/`quickAddTasks`/`backlog`), `dayRolloverTimer`, `everyMinuteTimer`, `initialSyncTimeoutFired` + `initialSyncDataArrived` (one-shot syncing-panel state machine, 3 s timeout), `extraDaysShown` capped at `extraDaysCap = 84`, `colorFilter` + `freeSlotFilter` (mutually exclusive: `.all`/`.onlyFree`/`.hideFree`), `backlogCoordinator`, `paletteContext: MenuBarPaletteContext?` |
| `BacklogFullscreenView.swift` | 2026 | Almost the entire file is `struct BacklogFullscreenView: View` (`:36`). Supporting type `BacklogScrollOffsetKey: PreferenceKey` extracted to its own file |
| `CommandPalette.swift` | 1275 | NL intent / quick action search |
| `Components/BacklogTaskRow.swift` | 1341 | Single-row component; large because rows render in many states (recurring, completed, locked, ghosted) |
| `Components/EventRowView.swift` | 1095 | Single-row component with similar state explosion |

Treat these as flagged for refactor candidacy — they are not bugs but they slow new contributors and increase merge-conflict risk. The most leveraged remaining split is `MenuBarView`'s main body per visual section. The permission-banner cluster + settings-button have already been extracted into `Presentation/Views/Components/`.

## Conventions

- Views consume `@Observable` services directly — no `ViewModel` for most screens. `Presentation/ViewModels/` is used only where state is non-trivial (settings, cloud sync). See [`viewmodels.md`](viewmodels.md).
- All sizes/colors/fonts/easing come from `DesignSystem.swift` (the `DS` namespace). Magic numbers in feature views are a smell.
- Skin-themable properties go through `BuboSkin.swift`. Skins can change mood (accent, tint, button weight) but not layout/materials/semantics — see [`../concepts/skins-system.md`](../concepts/skins-system.md).
- Design rules in `docs/design/PRINCIPLES.md` are normative for view code — see [`../concepts/design-principles.md`](../concepts/design-principles.md).
