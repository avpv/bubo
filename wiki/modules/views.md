# Module: Views

> **Kind:** module
> **Sources:** Bubo/Views/
> **Last ingest:** 2026-05-11
> **Related:** [`../concepts/menu-bar-popover.md`](../concepts/menu-bar-popover.md), [`../concepts/full-screen-alerts.md`](../concepts/full-screen-alerts.md), [`../concepts/design-principles.md`](../concepts/design-principles.md), [`skins.md`](skins.md)

## Layout

```
Views/
├── (top-level)        # Major screens, design tokens
├── Components/        # ~50 reusable widgets
└── Settings/          # Settings window tabs
```

## Top-level screens

| File | Role |
|---|---|
| `MenuBarView.swift` | Popover root — timeline + event list + actions + task add/edit stack |
| `SettingsView.swift` | Settings window root (tabbed) |
| `EventDetailView.swift` | Event detail + context menu |
| `AddEventView.swift` | Create-event form |
| `EditTaskView.swift` | Edit-task form |
| `NewTaskView.swift` | Quick-capture task creation |
| `QuickCaptureView.swift` | Global hotkey overlay (window owned by `AppDelegate`) |
| `FullScreenAlertView.swift` | Pre-meeting takeover ([J4](../concepts/full-screen-alerts.md)) |
| `JoinRibbonView.swift` | Post-join ribbon ([J1](../concepts/join-ribbon.md)) |
| `TimerScreenView.swift` | Pomodoro timer screen |
| `BacklogFullscreenView.swift` | Backlog list full-screen |
| `CommandPalette.swift` | NL intent / quick action search |
| `DesignSystem.swift` | `DS` namespace — global tokens (spacing, sizes, fonts, animations) |
| `BuboSkin.swift` | Active-skin provider for views |

## Settings (`Views/Settings/`)

| Tab | File |
|---|---|
| General | `GeneralTabView.swift` |
| Appearance | `AppearanceTabView.swift` |
| Calendars | `CalendarsTabView.swift` |
| Apple Reminders | `AppleRemindersTabView.swift` |
| Reminders (notifications) | `RemindersTabView.swift` |
| Optimizer | `OptimizerTabView.swift` |
| AI | `AITabView.swift` |
| Assistant | `AssistantTabView.swift` |
| World Clock | `WorldClockTabView.swift` |
| Container | `SettingsPlatter.swift` |

## Components (`Views/Components/`)

Grouped roughly:

- **Layout:** `FlowLayout`, `DaySectionView`, `AppBackgroundLayer`, `WallpaperBackgroundLayer`
- **Event/task rows:** `EventRowView`, `BacklogTaskRow`, `GhostEventRow`, `FreeSlotRow`, `ContextualActionRow`
- **Backlog:** `BacklogHeader`, `BacklogCapacityRing`, `BacklogProjectPicker`, `BacklogTombstones`, `TaskListExpansion`
- **Pickers:** `DateTimePickerPills`, `DurationPicker`, `RecurrencePickerView`, `EmojiPickerView`, `SegmentedPillPicker`, `PeakEnergyHoursPicker`, `WorkingDaysPicker`, `WorkingHoursBoundaryRow`, `SlotPickerPopover`, `DateSuggestionsPopover`, `DeadlinePickerPopover`
- **Popovers:** `SlotAlternativesPopover`, `SmartActions`, `SmartActionsBar`
- **Status / feedback:** `StatusBannerView`, `ToastView`, `EndOfDayBanner`, `EnergyCheckInBanner`, `RollForwardBanner`, `NowNextLine`
- **Utility:** `Chip`, `ColorDotButton`, `FreeSlotDotButton`, `OwlIcon`, `MarkdownText`, `FormattableTextView`, `InlineTimePicker`, `WorldClockStripView`, `DisintegrationEffect`

## Size hotspots

Top SwiftUI files by line count (as of last ingest — `wc -l` over `Bubo/Views/`):

| File | Lines | Notes |
|---|---:|---|
| `MenuBarView.swift` | 3521 | Popover root has accumulated timeline, event list, task add/edit, ghost previews, and command-palette plumbing. A candidate for splitting per sub-section |
| `BacklogFullscreenView.swift` | 2036 | Full-screen backlog list with sorting, project filters, drag-and-drop |
| `CommandPalette.swift` | 1275 | NL intent / quick action search |
| `Components/BacklogTaskRow.swift` | 1341 | Single-row component; large because rows render in many states (recurring, completed, locked, ghosted) |
| `Components/EventRowView.swift` | 1095 | Single-row component with similar state explosion |

Treat these as flagged for refactor candidacy — they are not bugs but they slow new contributors and increase merge-conflict risk. Splitting `MenuBarView` per visual section (header / timeline / event list / task stack) is the most leveraged change.

## Conventions

- Views consume `@Observable` services directly — no `ViewModel` for most screens. `ViewModels/` is used only where state is non-trivial (settings, cloud sync). See [`viewmodels.md`](viewmodels.md).
- All sizes/colors/fonts/easing come from `DesignSystem.swift` (the `DS` namespace). Magic numbers in feature views are a smell.
- Skin-themable properties go through `BuboSkin.swift`. Skins can change mood (accent, tint, button weight) but not layout/materials/semantics — see [`../concepts/skins-system.md`](../concepts/skins-system.md).
- Design rules in `docs/design/PRINCIPLES.md` are normative for view code — see [`../concepts/design-principles.md`](../concepts/design-principles.md).
