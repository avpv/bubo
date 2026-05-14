# Module: Views

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/
> **Last ingest:** 2026-05-14 (PR #531)
> **Related:** [`../concepts/menu-bar-popover.md`](../concepts/menu-bar-popover.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/design-principles.md`](../concepts/design-principles.md), [`skins.md`](skins.md)

## Layout

```
Presentation/Views/
├── (top-level)         # Major screens (MenuBar/, Timer/, EventDetail, design tokens)
├── Backlog/            # Full-screen backlog view + extensions
├── CommandPalette/     # CommandPalette + extensions (moved 2026-05-12 from Common/)
├── Components/         # ~70 reusable widgets (Banner/, Backlog/, Common/, Event/, Picker/, Slot/)
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
| `MenuBar/MenuBarView.swift` | `struct MenuBarView` (`:3`) | 222 | Popover root — composition only. `var body` is ~50 L: background + `navigationDestination()` + command palette + toast + keyboard shortcuts, plus the modifier chain. Fourteen logic/view clusters live in sibling extension files: prior nine (`+AutoDefer`, `+RollForward`, `+Pomodoro`, `+Timeline`, `+BacklogDrop`, `+Strings`, `+EventActions`, `+Permissions`, `+Focus`) plus five from the 2026-05-12 body decomposition (`+NavigationRoutes`, `+MainContent`, `+Lifecycle`, `+EventRow`, `+DayGroup`). Nested types extracted to file scope: `MenuBarNavigation`, `MenuBarPaletteContext`, `MenuBarDayListItem`, `MenuBarTimelineDay`. Permission banners + settings button live in `Presentation/Views/Components/`; preference keys in `Presentation/Views/MenuBar/MenuBarPreferenceKeys.swift` |
| `MenuBarNavigation.swift` | `enum MenuBarNavigation: Equatable` (`:9`) | 43 | 8-state navigation machine for the popover. Equality compares by event/task id |
| `MenuBarPaletteContext.swift` | `struct MenuBarPaletteContext: Equatable` (`:9`) | 21 | Seed-data carrier for the command palette overlay; nil on `MenuBarView.paletteContext` = hidden |
| `MenuBarDayListItem.swift` | `enum MenuBarDayListItem: Identifiable` (`:9`) | 30 | Row kind for the day list: event / free-slot / ghost / nowMarker |
| `Settings/SettingsView.swift` | `struct SettingsView` (`:4`) | 98 | Settings window with sidebar pane selector: General, Appearance, Calendars, Reminders, World Clock, Optimizer, Assistant |
| `Event/EventDetailView.swift` | `struct EventDetailView` (`:3`) | 630 | Event detail with metadata, Pomodoro badges, Focus-Filters tip for local/Pomodoro events, prep-scratchpad auto-expand, reschedule/extend menu actions |
| `Event/AddEventView.swift` | `struct AddEventView` (`:4`) | 652 | Event-creation form (title, date, duration, location, reminders, recurrence, Pomodoro). Two clusters live in sibling files: `+FindBestTime` and `+Pomodoro` |
| `Event/EditTaskView.swift` | `struct EditTaskView` (`:23`) | 813 | Full-screen task editor in nav stack. Sections for title / schedule / context / options. **Explicit Save** (not autosave) — matches event-editor model |
| `Event/NewTaskView.swift` | `struct NewTaskView` (`:17`) | 581 | Compact task creation. Sits between `QuickCaptureView` (minimal) and `EditTaskView` (full). Collapsed "More options" |
| `QuickCapture/QuickCaptureView.swift` | `struct QuickCaptureView` (`:12`) | 121 | One-line global-hotkey overlay. Return → submit to backlog. Shift+Return → open `NewTaskView`. Esc → cancel without saving |
| `FullScreenAlert/FullScreenAlertView.swift` | `struct FullScreenAlertView` (`:3`) | 358 | Pre-meeting takeover. Live countdown, Join/Dismiss, optional next-event hint, snooze menu, skin-tinted overlay |
| `Event/JoinRibbonView.swift` | `struct JoinRibbonView` (`:16`) | 92 | Post-join ribbon. Live countdown to start, meeting name, Re-alert action. Auto-dismisses at `startDate` |
| `Timer/TimerScreenView.swift` | `struct TimerScreenView` (`:3`) | 694 | Pomodoro/event timer. Live countdown ring. **Scrub gesture** adjusts `endDate`. **Pause gesture** shifts start+end. Wallpaper support. Pinned state |
| `Backlog/BacklogFullscreenView.swift` | `struct BacklogFullscreenView` (`:36`) | 952 | Full-popover task list. Inline editing, drag-reorder, urgency filter, smart-sort, hotkeys 1–9 for completion, optimizer presets, schedule/deadline actions. Three logic clusters in sibling files: `+BulkActions`, `+Reorder`, `+Actions`. `BacklogScrollOffsetKey: PreferenceKey` lives in its own file |
| `BacklogScrollOffsetKey.swift` | `struct BacklogScrollOffsetKey: PreferenceKey` (`:14`) | 18 | Publishes the task list's scroll offset to its parent for sticky-collapse of the filter band |
| `CommandPalette/CommandPalette.swift` | `struct CommandPalette` (`:14`) | 784 | Smart suggestion palette. AI intent composition, event/task search, optimization presets, **dry-run preview**, "power mode" for advanced users. Three clusters in sibling files: `+PowerMode`, `+Status`, `+Actions`. Moved 2026-05-12 from `Views/Common/` to its own folder |
| `DesignSystem/DesignSystem.swift` + 7 siblings | `enum DS` (`:20`) | 530 + 722 + | The 1228-line catalog was split across `DS+Layout` (Spacing, Density, Hero, Popover, Grid, SettingsWindow, EmptyState), `DS+Typography`, `DS+Sizes` (Component sizes, Border, Opacity), `DS+Visual` (Shadows, Elevation, Physics, Animation), `DS+Colors` (Semantic, Materials, EventColorTag, Urgency, Countdown), `DS+Formatting` (SnoozeOption, Ordinal, Time, Shared formatters). PR #531 added `DS+Prototype.swift` — four semantic enums that bridge the HTML prototype tokens into Swift: `DS.Fg` (four-step opacity ramp: `primaryOpacity`=1.0, `secondaryOpacity`=0.7, `tertiaryOpacity`=0.45, `dividerOpacity`=0.12); `DS.Mix` (translucent surface and accent mix percentages, e.g. `surfaceChip`=0.05, `accentBg`=0.05, `accentStrong`=0.22); `DS.PopoverShadow` (three-tier shadows: default `radius`=40/`y`=14/`opacity`=0.40, `.palette` 50/18/0.55, `.alert` 80/30/0.55); `DS.Motion` (`micro` = 120 ms ease for hover transitions). New views should reach for `DS.Mix` / `DS.Fg` / `DS.PopoverShadow` instead of inline magic numbers. `DesignSystem.swift` itself keeps only the `enum DS` namespace + the `Haptics` enum + the View / Text / EnvironmentValues extensions that depend on DS tokens. Call sites unchanged (`DS.Spacing.sm`, `DS.Colors.surfacePrimary`, …). |
| `BuboSkin.swift` (relocated) | `struct SkinBackgroundLayer` (`:5`) | 286 | Now at `Presentation/Views/Skins/BuboSkin.swift` — see [`skins.md`](skins.md) |

## Settings (`Presentation/Views/Settings/`)

| Tab | File | Type+line | Lines | Role |
|---|---|---|---:|---|
| General | `GeneralTabView.swift` | `struct GeneralTabView` (`:454`) | 575 | General prefs — badge mode, theme/skin preview cards (plus 6 sub-view structs in same file: `ThemeColorPreview :5`, `SkinPreviewCard :30`, `CustomSkinsSection :108`, `BackgroundPhotoSection :205`, `WallpaperSectionView :336`, `CloudSyncStatusSection :396`) |
| Appearance | `AppearanceTabView.swift` | `struct AppearanceTabView` (`:3`) | 50 | Skin grid (`LazyVGrid`), custom skins, wallpaper picker, background photo |
| Calendars | `CalendarsTabView.swift` | `struct CalendarsTabView` (`:3`) | 179 | Calendar access toggle + calendar selection. Refreshes auth on appear; auto-syncs on permission grant; rebuilds `EKEventStore` |
| Apple Reminders | `AppleRemindersTabView.swift` | `struct AppleRemindersTabView` (`:3`) | 422 | Sync toggle, list selection, import/export, schedule alarms. Auto-syncs on permission grant |
| Reminders (notifications) | `RemindersTabView.swift` | `struct RemindersTabView` (`:3`) | 64 | Reminder interval list, stepper-to-add, full-screen vs system-notification toggle |
| Optimizer | `OptimizerTabView.swift` | `struct OptimizerTabView` (`:5`) | 155 | Working hours (0–23), working days, default task duration `[15, 30, 60, 90]` min. PR #531 added two `SettingsPlatter` cards at the top: `DelegationContractView` (contract card) and `OptimizerInsightsView` (track-record card). |
| — | `DelegationContractView.swift` | `struct DelegationContractView` (`:18`) | — | Static "I will / I will never" delegation contract. Makes the optimizer's operating rules explicit and findable — shown first in the Optimizer tab and also surfaced on first launch. No state, no actions. |
| — | `OptimizerInsightsView.swift` | `struct OptimizerInsightsView` (`:16`) | — | Reads `IntentLearner.history`, `intentFrequency`, `temporalPatterns` and renders three metric tiles (plans run, acceptance %, pattern count) plus a top-patterns list (busiest hour, favourite intent, busiest weekday). Empty state shown until at least one plan is run. Capped at 200-history entries. |
| AI | `AITabView.swift` | `struct AITabView` (`:5`) | 229 | Agent mode picker (built-in proxy vs own API key), key input, usage stats, privacy disclosure |
| Assistant | `AssistantTabView.swift` | `struct AssistantTabView` (`:10`) | 256 | Backlog cleanup nudge for stale tasks + AI mode/key/usage/privacy. Note: schedule settings live in the Optimizer tab now |
| World Clock | `WorldClockTabView.swift` | `struct WorldClockTabView` (`:3`) | 178 | Enable toggle, city search/filter, selected list with timezone IDs, drag-reorder |
| Container | `SettingsPlatter.swift` | `struct SettingsPlatter` (`:3`) | 35 | Reusable settings card with optional title; skin-aware typography and platter styling |

## Components (`Presentation/Views/Components/`)

~70 SwiftUI components across `Components/{Background,Backlog,Banner,Common,Event,Picker,Slot}/`. Grouped by role; line numbers cite the main type declaration.

### Layout (4)
- `FlowLayout` (`FlowLayout.swift:7`) — `struct FlowLayout: Layout`
- `DaySectionView` — `DaySectionHeader<Trailing: View>` (`:4`)
- `AppBackgroundLayer` (`:3`) — layered backgrounds (wallpaper + custom photo + skin + surface tint)
- `WallpaperBackgroundLayer` (`:5`) — wallpaper with parallax offset and overscan. Supports solid color, gradient, pattern, live

### Banners (2, added PR #531)
- `MorningBriefBanner` (`Banner/MorningBriefBanner.swift:33`) — E1 persistent receipt shown once per calendar day on the first popover open after AutoDefer runs. Reads three `@AppStorage` keys (`BuboMorningBriefDay`, `BuboMorningBriefDeferred`, `BuboMorningBriefDismissedDay`) written by `MenuBarView.runAutoDeferIfNeeded`. Optional `onShowDetails` routes to the backlog when deferred count > 0.
- `ProactiveCapacityNotice` (`Banner/ProactiveCapacityNotice.swift`) — Main-Job fix #3 capacity pushback. Shows when `BacklogLogic.CapacityForecast` is `.over` or `.afterHours`; surfaces diagnosis + one-tap remedies (defer tasks, extend day, run optimizer). Uses `TipBanner` shell with destructive/warning tone.

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

### Prototype-aligned atoms (20, added PR #531)

These components implement the HTML prototype spec (`docs/refactor/prototype-spec.md`). All use `DS.Fg`, `DS.Mix`, and `DS.PopoverShadow` tokens instead of magic numbers.

- `OptimizerRulesStrip` (`Common/OptimizerRulesStrip.swift:24`, 232 L) — scrollable chip row that surfaces every active optimizer rule (working hours, working days, peak energy hours, locked/excluded event counts, capacity forecast). Shown permanently below the popover header. Tap on a chip routes to Settings > Optimizer. Main-Job fix #6.
- `ScenarioPickerBar` (`Common/ScenarioPickerBar.swift:7`, 215 L) — horizontal tab strip for comparing optimizer Pareto-front scenarios after a Plan run. Each tab is one `ScenarioPick`; "Apply" commits the active scenario via `OptimizerService`. Main-Job fix #4 (J4).
- `AvailabilityComposer` (`Common/AvailabilityComposer.swift`, `enum`, 138 L) — pure utility: formats the next N free slots from `FreeSlotFinder` into copy-ready plain text (locale-aware, monospace-friendly). Used by `FooterActions.copyAvailabilityMenuItem`. S2 fix.
- `PopoverShell` (`Common/PopoverShell.swift`, 124 L) — shared wrapper for all popover surfaces: `.regularMaterial` blur, `DS.PopoverShadow` depth (`.default` / `.palette` / `.alert`), 14 pt corner radius, 0.5 px hairline border, optional skin halo.
- `SegmentedTabs` (`Common/SegmentedTabs.swift`, `enum SegmentedTabsStyle`, 121 L) — generic tab strip in two styles (`.pill` and `.underline`); used by `ScenarioPickerBar` and any picker that needs switchable views.
- `TipBanner` (`Common/TipBanner.swift`, `enum BannerTone`, 123 L) — parameterized banner shell with `BannerTone` (`.success`, `.warning`, `.destructive`, `.neutral`). Base for `MorningBriefBanner` and `ProactiveCapacityNotice`; supports multi-action trailing area + dismiss button.
- `WorkingHoursLine` (`Common/WorkingHoursLine.swift`, `enum WorkingHoursEdge`, 129 L) — horizontal rule pair marking start/end of working hours on the timeline. Renders as `DS.Fg.dividerOpacity` hairlines with `DS.Spacing` insets matching the prototype `wh-rule`.
- `EventStripe` (`Common/EventStripe.swift`, `enum EventStripeVariant`, 108 L) — colored left-edge stripe for event/task rows. Encodes calendar color, Pomodoro state, and conflict status as stripe width + opacity variants.
- `AvatarStack` (`Common/AvatarStack.swift`, `struct Avatar: Hashable`, 110 L) — horizontal overlap stack for attendee/collaborator avatars. Punch-out separator uses `DS.Mix.surfaceSeparator` (14 %).
- `PlatformChip` (`Common/PlatformChip.swift`, `enum CallPlatform`, 98 L) — meeting-platform badge (Zoom, Meet, Teams, phone, …). `CallPlatform` is `CaseIterable` with a `systemImage` and a tint. Used in `EventRowView` hover cluster.
- `RsvpChip` (`Common/RsvpChip.swift`, `enum RsvpStatus`, 69 L) — RSVP status badge (accepted / declined / tentative / needsAction). Orange for declined, green for accepted. Used in event rows.
- `KbdChip` (`Common/KbdChip.swift`, 68 L) — keyboard shortcut chip, `DS.Mix.surfaceKbd` (7 %) background, monospaced caption. Used in command-palette and tooltip affordances.
- `CompletionCheckbox` (`Common/CompletionCheckbox.swift`, 69 L) — animated checkbox for task completion. Checked state: `--system-green` fill with checkmark; unchecked: `DS.Mix.surfaceIcon` ring.
- `ToggleSwitch` (`Common/ToggleSwitch.swift`, 61 L) — custom toggle in prototype style (no native macOS toggle); ON state uses `--system-green` track.
- `IconButton` (`Common/IconButton.swift`, 59 L) — icon-only button with `DS.Mix.surfaceIcon` (10 %) background, `DS.Mix.accentHover` on hover. Used throughout the popover header and row affordances.
- `ProgressBar` (`Common/ProgressBar.swift`, 43 L) — linear fill bar; track uses `DS.Mix.surfaceDivider` (8 %). Used by `OptimizerInsightsView` and capacity surfaces.
- `CalDot` (`Common/CalDot.swift`, `enum CalDotSize`, 42 L) — tiny colored dot for calendar source identity. Replaces inline `Circle().fill(color)` calls so the sizing is consistent.
- `WhenChip` (`Common/WhenChip.swift`, 42 L) — scheduled-time badge on backlog task rows. Orange tint for unscheduled, accent for scheduled.
- `TimelineNowRule` (`Common/TimelineNowRule.swift`, 47 L) — the «NOW ·‌ H:mm» hairline rule in the day timeline, extracted from `MenuBarView+MainContent`. Replaces `nowMarkerRow(_:)` inline code.
- `SourcePickerChip` (`Common/SourcePickerChip.swift`) — calendar-source filter chip in the popover header. `DS.Mix.surfaceChip` (5 %) at rest, `DS.Mix.accentLight` (8 %) when selected.

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
- `FooterActions` (`Common/FooterActions.swift`) — PR #531 added `workingHours: ClosedRange<Int>?` and `workingDays: Set<Int>?` parameters so the "Copy availability" menu item (S2 fix) can filter free slots to the user's actual workday. `AvailabilityComposer` does the formatting; the parameters are optional so preview surfaces and callers without an optimizer keep prior behaviour.

Re-list: `find Bubo/Presentation/Views/Components -name '*.swift' | wc -l`.

## Size hotspots

Top SwiftUI files by line count.

| File | Lines | Top-level structure (verified by `grep -n '^struct\|^private struct'`) |
|---|---:|---|
| `MenuBar/MenuBarView.swift` | 222 | State surface + ~50 L body (composition only). Body = `AppBackgroundLayer` → `Group { navigationDestination() }` → `commandPaletteOverlay()` → `ToastOverlay` → `keyboardShortcutsLayer()`, plus modifier chain calling out to `handleAppear` / `handleDisappear` / per-notification handlers. Fourteen sibling extensions: **prior nine** — `+AutoDefer` (162, midnight rollover + EOD banner), `+RollForward` (180, J-Recover + focus-slot fill + overdue reschedule), `+Pomodoro` (206, convertEventToPomodoro + clone-as-draft + ripple-shift + slot Pomodoro), `+Timeline` (163, `filteredEventsByDay`/`timelineEventsByDay`/`visibleEventCount`/`timelineDays`/`interleave`/`startOf`/`ghostForDay`), `+BacklogDrop` (230, `handleTaskDrop`+`scheduleBacklogTask`+`scheduleSlotPickerBatch`), `+Strings` (133, pure-compute strings), `+EventActions` (76, `resolveEdit`/`handleDelete`/`notifyScheduleChange`/`runQuickAction`), `+Permissions` (71, `permissionBannerSpecs`/`refreshPermissionSnapshots`/`showSyncingState`), `+Focus` (83, day-nav cluster state); **five from 2026-05-12 body decomposition** — `+NavigationRoutes` (406, one `@ViewBuilder` per `MenuBarNavigation` case + `navigationDestination()` dispatcher), `+MainContent` (446, `mainContent`/`eventList`/`syncingState`/`parallaxOffset`/`nowMarkerRow`/`nowMarkerLabel`/`dayNavCluster`), `+Lifecycle` (239, `commandPaletteOverlay`/`keyboardShortcutsLayer`/`handleAppear`/`handleDisappear` + per-notification handlers), `+EventRow` (205, `eventRow(_:)` with 15+ row callbacks), `+DayGroup` (190, `dayGroupHeader`/`dayGroupSection`/`freeSlotRow`/`collapsedEventsHeader`). State surface (~30 `@State` fields), notable: `navigation: MenuBarNavigation`, `dayRolloverTimer`, `everyMinuteTimer` (only thing still `private` — only used in body), `initialSyncTimeoutFired` + `initialSyncDataArrived`, `extraDaysShown` capped at `extraDaysCap = 84`. The 2026-05-12 split also relaxed `paletteContext`, `listScrollY`, `showingQuickCapture`, `dismissedBannerIds`, `optimizerBottomY`, `initialSyncTimeoutFired`, `openSettings`, `reduceMotion`, `skin`, `activeSkin`, `extraDaysCap` from `private` to internal for cross-file access. |
| `Backlog/BacklogFullscreenView.swift` | 952 | Body + computed properties + subview helpers + filter chrome. Three logic clusters split out 2026-05-12: `+BulkActions.swift` (131, multi-select schedule/defer/freeze/delete + tombstone undo), `+Reorder.swift` (132, up/down/edge moves + drag-reorder drop), `+Actions.swift` (147, per-task CRUD + inline-add). All `@State`/`@FocusState`/`@Environment` wrappers are internal so siblings can read/write. |
| `CommandPalette/CommandPalette.swift` | 784 | NL intent / quick action search. Three clusters split out 2026-05-12: `+PowerMode.swift` (216, progressive-disclosure composer for OptimizationRequest), `+Status.swift` (133, status/applied/failed result surfaces), `+Actions.swift` (172, handleSubmit/runRequest + keyboard shortcuts). |
| `Components/Backlog/BacklogTaskRow.swift` | 730 | Single-row component. `BacklogTaskRow+Subviews.swift` (601) holds drag payload + checkbox/content/controls/background/focus-ring/scheduled-chip helpers; `OverduePulseDot.swift` (25) lifted to its own file. |
| `Components/Event/EventRowView.swift` | 721 | Single-row component. Three clusters split out 2026-05-12: `+Title.swift` (102, inline rename gate + commit/cancel), `+DragReschedule.swift` (134, vertical drag with minute snapping + preview badge), `+HoverActions.swift` (169, snooze/complete/disintegration-delete/reminder menu). |
| `Event/AddEventView.swift` | 652 | Event-creation form. Two clusters split out 2026-05-12: `+FindBestTime.swift` (117, optimizer-driven slot suggestion + helpers), `+Pomodoro.swift` (347, toggle + section + timeline preview + recurrence-rule builder). |

Treat these as flagged for further decomposition only if needed — successive logic splits brought every "mega-file" below ~1000 lines. `MenuBarView.swift` is now composition only at 222 L; the remaining extension files are 200–450 L each, all single-concern and ready for direct edits.

## Conventions

- Views consume `@Observable` services directly — no `ViewModel` for most screens. `Presentation/Views/Settings/` is used only where state is non-trivial (settings, cloud sync). See [`viewmodels.md`](viewmodels.md).
- All sizes/colors/fonts/easing come from `DesignSystem.swift` (the `DS` namespace). Magic numbers in feature views are a smell. Prototype-aligned surfaces also use `DS.Fg`, `DS.Mix`, and `DS.PopoverShadow` from `DS+Prototype.swift`.
- Skin-themable properties go through `BuboSkin.swift`. Skins can change mood (accent, tint, button weight) but not layout/materials/semantics — see [`../concepts/skins-system.md`](../concepts/skins-system.md).
- Design rules in `docs/design/PRINCIPLES.md` are normative for view code — see [`../concepts/design-principles.md`](../concepts/design-principles.md).
