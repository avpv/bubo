# Module: Views

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/
> **Last ingest:** 2026-05-15 (rev2: main surfaces declutter pass for MenuBar + Backlog + Timer) (rev: struct line/total-line refs resynced (+1 to +3 drift); `BacklogFullscreenView` shrank 952→765 L; `BacklogScrollOffsetKey.swift` row removed — the file no longer exists; MenuBar preference keys file now declares `OptimizerBottomKey` only)
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
| `MenuBar/MenuBarView.swift` | `struct MenuBarView` (`:4`) | 211 | Popover root — composition only. Added compact focus-summary counters (today events / pending tasks / free slots) and shortened optimizer CTA label for lower cognitive load. `var body` is ~50 L: background + `navigationDestination()` + command palette + toast + keyboard shortcuts, plus the modifier chain. Fourteen logic/view clusters live in sibling extension files: prior nine (`+AutoDefer`, `+RollForward`, `+Pomodoro`, `+Timeline`, `+BacklogDrop`, `+Strings`, `+EventActions`, `+Permissions`, `+Focus`) plus five from the 2026-05-12 body decomposition (`+NavigationRoutes`, `+MainContent`, `+Lifecycle`, `+EventRow`, `+DayGroup`). Nested types extracted to file scope: `MenuBarNavigation`, `MenuBarPaletteContext`, `MenuBarDayListItem`, `MenuBarTimelineDay`. Permission banners + settings button live in `Presentation/Views/Components/`; preference keys (`OptimizerBottomKey`) in `Presentation/Views/MenuBar/MenuBarPreferenceKeys.swift:13` |
| `MenuBarNavigation.swift` | `enum MenuBarNavigation: Equatable` (`:9`) | 43 | 8-state navigation machine for the popover. Equality compares by event/task id |
| `MenuBarPaletteContext.swift` | `struct MenuBarPaletteContext: Equatable` (`:9`) | 21 | Seed-data carrier for the command palette overlay; nil on `MenuBarView.paletteContext` = hidden |
| `MenuBarDayListItem.swift` | `enum MenuBarDayListItem: Identifiable` (`:9`) | 30 | Row kind for the day list: event / free-slot / ghost / nowMarker |
| `Settings/SettingsView.swift` | `struct SettingsView` (`:5`) | 99 | Settings window with sidebar pane selector: General, Appearance, Calendars, Reminders, World Clock, Optimizer, Assistant |
| `Event/EventDetailView.swift` | `struct EventDetailView` (`:4`) | 631 | Event detail with metadata, Pomodoro badges, Focus-Filters tip for local/Pomodoro events, prep-scratchpad auto-expand, reschedule/extend menu actions |
| `Event/AddEventView.swift` | `struct AddEventView` (`:6`) | 654 | Event-creation form (title, date, duration, location, reminders, recurrence, Pomodoro). Two clusters live in sibling files: `+FindBestTime` and `+Pomodoro` |
| `Event/EditTaskView.swift` | `struct EditTaskView` (`:20`) | 828 | Full-screen task editor in nav stack. Sections for title / schedule / context / options. **Explicit Save** (not autosave) — matches event-editor model |
| `Event/NewTaskView.swift` | `struct NewTaskView` (`:18`) | 594 | Compact task creation. Sits between `QuickCaptureView` (minimal) and `EditTaskView` (full). Collapsed "More options" |
| `QuickCapture/QuickCaptureView.swift` | `struct QuickCaptureView` (`:13`) | 122 | One-line global-hotkey overlay. Return → submit to backlog. Shift+Return → open `NewTaskView`. Esc → cancel without saving |
| `FullScreenAlert/FullScreenAlertView.swift` | `struct FullScreenAlertView` (`:4`) | 359 | Pre-meeting takeover. Live countdown, Join/Dismiss, optional next-event hint, snooze menu, skin-tinted overlay |
| `Event/JoinRibbonView.swift` | `struct JoinRibbonView` (`:17`) | 93 | Post-join ribbon. Live countdown to start, meeting name, Re-alert action. Auto-dismisses at `startDate` |
| `Timer/TimerScreenView.swift` | `struct TimerScreenView` (`:4`) | 695 | Pomodoro/event timer. Live countdown ring. **Scrub gesture** adjusts `endDate`. **Pause gesture** shifts start+end. Added compact header context pills (time range + location) to reduce hunt time. Wallpaper support. Pinned state |
| `Backlog/BacklogFullscreenView.swift` | `struct BacklogFullscreenView` (`:38`) | 765 | Full-popover task list. Inline editing, drag-reorder, urgency filter, smart-sort, hotkeys 1–9 for completion, optimizer presets, schedule/deadline actions. Added focus summary pills (active count, workload, today-left) above task stream. Three logic clusters in sibling files: `+BulkActions`, `+Reorder`, `+Actions`. |
| `CommandPalette/CommandPalette.swift` | `struct CommandPalette` (`:16`) | 788 | Smart suggestion palette. AI intent composition, event/task search, optimization presets, **dry-run preview**, "power mode" for advanced users. Three clusters in sibling files: `+PowerMode`, `+Status`, `+Actions`. Moved 2026-05-12 from `Views/Common/` to its own folder |
| `DesignSystem/DesignSystem.swift` + 7 siblings | `enum DS` (`:21`), `enum Haptics` (`:30`) | 541 + 900 (sum of 7 siblings) | Catalog split across `DS+Layout` (Spacing, Density, Hero, Popover, Grid, SettingsWindow, EmptyState — 112 L), `DS+Typography` (117 L), `DS+Sizes` (Component sizes, Border, Opacity — 194 L), `DS+Visual` (Shadows, Elevation, Physics, Animation — 170 L), `DS+Colors` (Semantic, Materials, EventColorTag, Urgency, Countdown — 99 L), `DS+Formatting` (SnoozeOption, Ordinal, Time, Shared formatters — 71 L), `DS+Prototype` (137 L). `DesignSystem.swift` itself keeps the `enum DS` namespace + the `Haptics` enum + the View / Text / EnvironmentValues extensions that depend on DS tokens. Call sites unchanged (`DS.Spacing.sm`, `DS.Colors.surfacePrimary`, …). |
| `BuboSkin.swift` (relocated) | `struct SkinBackgroundLayer` (`:5`) | 286 | Now at `Presentation/Views/Skins/BuboSkin.swift` — see [`skins.md`](skins.md) |

## Settings (`Presentation/Views/Settings/`)

| Tab | File | Type+line | Lines | Role |
|---|---|---|---:|---|
| General | `GeneralTabView.swift` | `struct GeneralTabView` (`:455`) | 576 | General prefs — badge mode, theme/skin preview cards (plus 6 sub-view structs in same file: `ThemeColorPreview :6`, `SkinPreviewCard :31`, `CustomSkinsSection :109`, `BackgroundPhotoSection :206`, `WallpaperSectionView :337`, `CloudSyncStatusSection :397`) |
| Appearance | `AppearanceTabView.swift` | `struct AppearanceTabView` (`:4`) | 51 | Skin grid (`LazyVGrid`), custom skins, wallpaper picker, background photo |
| Calendars | `CalendarsTabView.swift` | `struct CalendarsTabView` (`:5`) | 181 | Calendar access toggle + calendar selection. Refreshes auth on appear; auto-syncs on permission grant; rebuilds `EKEventStore` |
| Apple Reminders | `AppleRemindersTabView.swift` | `struct AppleRemindersTabView` (`:5`) | 424 | Sync toggle, list selection, import/export, schedule alarms. Auto-syncs on permission grant |
| Reminders (notifications) | `RemindersTabView.swift` | `struct RemindersTabView` (`:4`) | 65 | Reminder interval list, stepper-to-add, full-screen vs system-notification toggle |
| Optimizer | `OptimizerTabView.swift` | `struct OptimizerTabView` (`:6`) | 171 | Working hours (0–23), working days, default task duration `[15, 30, 60, 90]` min |
| AI | `AITabView.swift` | `struct AITabView` (`:5`) | 229 | Agent mode picker (built-in proxy vs own API key), key input, usage stats, privacy disclosure |
| Assistant | `AssistantTabView.swift` | `struct AssistantTabView` (`:11`) | 257 | Backlog cleanup nudge for stale tasks + AI mode/key/usage/privacy. Note: schedule settings live in the Optimizer tab now |
| World Clock | `WorldClockTabView.swift` | `struct WorldClockTabView` (`:4`) | 179 | Enable toggle, city search/filter, selected list with timezone IDs, drag-reorder |
| Container | `SettingsPlatter.swift` | `struct SettingsPlatter` (`:3`) | 35 | Reusable settings card with optional title; skin-aware typography and platter styling |

## Components (`Presentation/Views/Components/`)

66 SwiftUI components across `Components/{Background,Backlog,Banner,Common,Event,Picker,Slot}/`. Grouped by role; line numbers cite the main type declaration.

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
- `LoadMoreDaysButton` (`Components/LoadMoreDaysButton.swift`) — quiet full-width footer below the timeline that fires the host's «extend horizon by one week» closure.

Re-list: `find Bubo/Presentation/Views/Components -name '*.swift' | wc -l`.

## Size hotspots

Top SwiftUI files by line count.

| File | Lines | Top-level structure (verified by `grep -n '^struct\|^private struct'`) |
|---|---:|---|
| `MenuBar/MenuBarView.swift` | 211 | State surface + ~50 L body (composition only). Body = `AppBackgroundLayer` → `Group { navigationDestination() }` → `commandPaletteOverlay()` → `ToastOverlay` → `keyboardShortcutsLayer()`, plus modifier chain calling out to `handleAppear` / `handleDisappear` / per-notification handlers. Fourteen sibling extensions: **prior nine** — `+AutoDefer`, `+RollForward`, `+Pomodoro`, `+Timeline`, `+BacklogDrop`, `+Strings`, `+EventActions`, `+Permissions`, `+Focus`; **five from 2026-05-12 body decomposition** — `+NavigationRoutes`, `+MainContent`, `+Lifecycle`, `+EventRow`, `+DayGroup`. State surface (~30 `@State` fields), notable: `navigation: MenuBarNavigation`, `dayRolloverTimer`, `everyMinuteTimer`, `initialSyncTimeoutFired` + `initialSyncDataArrived`, `extraDaysShown` capped at `extraDaysCap = 84`. |
| `Backlog/BacklogFullscreenView.swift` | 765 | Body + computed properties + subview helpers + filter chrome. Three logic clusters split out 2026-05-12: `+BulkActions.swift`, `+Reorder.swift`, `+Actions.swift`. All `@State`/`@FocusState`/`@Environment` wrappers are internal so siblings can read/write. |
| `CommandPalette/CommandPalette.swift` | 788 | NL intent / quick action search. Three clusters split out 2026-05-12: `+PowerMode.swift`, `+Status.swift`, `+Actions.swift`. |
| `Components/Backlog/BacklogTaskRow.swift` | 730 | Single-row component. `BacklogTaskRow+Subviews.swift` (601) holds drag payload + checkbox/content/controls/background/focus-ring/scheduled-chip helpers; `OverduePulseDot.swift` (25) lifted to its own file. |
| `Components/Event/EventRowView.swift` | 721 | Single-row component. Three clusters split out 2026-05-12: `+Title.swift` (102, inline rename gate + commit/cancel), `+DragReschedule.swift` (134, vertical drag with minute snapping + preview badge), `+HoverActions.swift` (169, snooze/complete/disintegration-delete/reminder menu). |
| `Event/AddEventView.swift` | 652 | Event-creation form. Two clusters split out 2026-05-12: `+FindBestTime.swift` (117, optimizer-driven slot suggestion + helpers), `+Pomodoro.swift` (347, toggle + section + timeline preview + recurrence-rule builder). |

Treat these as flagged for further decomposition only if needed — successive logic splits brought every "mega-file" below ~1000 lines. `MenuBarView.swift` is now composition only at 222 L; the remaining extension files are 200–450 L each, all single-concern and ready for direct edits.

## Conventions

- Views consume `@Observable` services directly — no `ViewModel` for most screens. `Presentation/Views/Settings/` is used only where state is non-trivial (settings, cloud sync). See [`viewmodels.md`](viewmodels.md).
- All sizes/colors/fonts/easing come from `DesignSystem.swift` (the `DS` namespace). Magic numbers in feature views are a smell.
- Skin-themable properties go through `BuboSkin.swift`. Skins can change mood (accent, tint, button weight) but not layout/materials/semantics — see [`../concepts/skins-system.md`](../concepts/skins-system.md).
- Design rules (formerly in `docs/design/PRINCIPLES.md`, now captured only in the wiki) are normative for view code — see [`../concepts/design-principles.md`](../concepts/design-principles.md).
