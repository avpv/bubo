# Apple HIG Compliance — Audit & Fixes

Audit of the presentation layer against six Apple HIG areas
([Layout and organization](https://developer.apple.com/design/human-interface-guidelines/layout-and-organization),
[Menus and actions](https://developer.apple.com/design/human-interface-guidelines/menus-and-actions),
[Navigation and search](https://developer.apple.com/design/human-interface-guidelines/navigation-and-search),
[Presentation](https://developer.apple.com/design/human-interface-guidelines/presentation),
[Selection and input](https://developer.apple.com/design/human-interface-guidelines/selection-and-input),
[Status](https://developer.apple.com/design/human-interface-guidelines/status)),
cross-checked against `PRINCIPLES.md` so deliberate house rules aren't
"fixed" into generic defaults. Where HIG and PRINCIPLES agree, the fix
cites both.

## Fixed (2026-07-16)

### Menus & actions

| # | Finding | Fix |
|---|---|---|
| M1 | Menu/button labels mixed sentence case with Title Case («Find a slot now» next to «Move Up»). HIG menus: title-style capitalization. | Relabeled across `EventRowView`, `BacklogTaskRow`, `FreeSlotRow`, `FooterActions`, `GeneralTabView`: «Pin in Place», «Exclude from Optimization», «Find a Slot Now», «Set Deadline…», «Split into Shorter Blocks», «Mark/Clear Urgent», «Prefer Time of Day», «Lock as Focus Block», «Start Pomodoro Here», «Edit Details…», «Remove Skin…», snooze «1 Day / 3 Days / 1 Week». |
| M2 | Context-menu items dimmed instead of hidden (Move Up/Down/To Top/To Bottom on first/last rows; the active period in the period submenu). HIG context menus: «hide unavailable items, don't dim them». | Reorder verbs now render conditionally and live in one `Menu("Move")` submenu (the repeated-term rule); the period submenu uses `Toggle` rows so the active period reads as a native checkmark and toggles off to clear. |
| M3 | Event context menu buried its frequent verbs — Edit sat second-to-last under ~7 optimizer verbs. | Complete Task + Edit… lead the menu; Pin/Exclude/Find Better Time/Split/Protect/Convert/Repeat collapsed into one «Optimize» submenu, gated so it never renders empty. |
| M4 | «Copy availability…» carried an ellipsis but completes immediately; «Settings» opens a window without one. | «Copy Availability» (no ellipsis); «Settings…» (ellipsis). |
| M5 | «Quit Bubo» was `role: .destructive` (red). Quitting destroys no data. | Plain button. |
| M6 | Icon-only footer «More» menu and the reminder-row trash button lacked accessibility labels/tooltips. | `.accessibilityLabel("More")`; `.help` + label on «Remove reminder». |
| M7 | Custom-skin deletion was a one-click irreversible context-menu action. | `confirmationDialog` («Remove Skin» destructive / Cancel) before deleting the file. |

### Navigation & search

| # | Finding | Fix |
|---|---|---|
| N1 | Escape double-bound on the event/task forms: header Back and footer Cancel both claimed Esc, and only Cancel was draft-aware — Esc could silently skip draft save. | `PopoverHeader` gained `backBindsEscape`; the three forms pass `false` so Cancel (`.cancelAction`) is the single Esc owner, and `AddEventView`'s Back now routes through the same draft-aware `cancelAndDismiss()`. Pushed (non-modal) screens keep the Esc-back binding. |
| N2 | Day navigation was pointer-only. HIG toolbars: every toolbar verb needs a command path. | ⌘← / ⌘→ previous/next day, ⌥⌘T today (⌘T is taken by Tasks); tooltips document the keys. |
| N3 | Palette idle icon was `sparkles` though the field runs a live search; placeholder didn't name the search scope; event results needed 2 chars while presets filtered from 1. | Idle state shows `magnifyingglass`; placeholder «Search events or plan your day…»; both result sections now refine from the first character. |

### Presentation

| # | Finding | Fix |
|---|---|---|
| P1 | Full-screen alert put the default action (Join, bound to ↩) on the leading side and Dismiss trailing — reversed per HIG alerts. | Dismiss leads, Join trails. |
| P2 | Quick-capture panel never dismissed on click-outside despite its own «Esc or click-outside» contract. | `windowDidResignKey` on the AppDelegate window delegate dismisses the panel when it loses key. |
| P3 | Quick-capture used `.hudWindow` material for a control-bearing input panel. HIG: HUDs are for media/overlay chrome without controls. | `.popover` content material. |
| P4 | Settings window title was «Pane \| Bubo». | Just the pane name, per System Settings convention. |
| P5 | Reduce Motion still bounced the alert bell (slower, not off). | Static bell under Reduce Motion. |

### Layout & organization

| # | Finding | Fix |
|---|---|---|
| L1 | Day-section header (15/11pt) and the stacked popover header (15/11pt) used pinned point sizes instead of text styles. | Routed through `DS.Typography.headline` / `.subhead` (title3/footnote). |
| L2 | Raw `.subheadline` appeared at 13 call sites despite the ramp's «no .subheadline outside this enum» rule. | New sanctioned ramp voice `DS.Typography.row` (`.subheadline`, skin design/weight); row titles, shelf rows, action rows, footer verbs migrated. |
| L3 | Event time column was a fixed 78pt frame with no wrap guard — 12-hour locales could fold the range. | `.lineLimit(1).fixedSize()` on the time pair, column `minWidth` instead of fixed width. |
| L4 | Optimizer settings pinned control widths (90/100/120pt) that clip localized labels. | `minWidth` so controls can grow. |
| L5 | Unscheduled-shelf disclosure chevron trailed the row; macOS disclosure rows anchor the triangle at the leading edge. | Indicator moved to the leading edge (right when collapsed, down when expanded). |

### Selection & input

| # | Finding | Fix |
|---|---|---|
| S1 | Form placeholders drew in `resolvedTextSecondary` — dark enough to read as filled content; three placeholder colors coexisted. | All 16 form prompts now use `resolvedTextTertiary` (matches `QuickAddView`). |
| S2 | Single-boolean rows wore `.switch` while sibling rows wore checkboxes. HIG toggles: don't replace a checkbox with a switch; switches emphasize masters. | Switches kept only on section masters (calendar sync, reminders sync, export, Pomodoro mode, Repeats); Date/Urgent/Has-deadline and the Reminders sub-options are checkboxes. |
| S3 | DurationPicker's «type an exact value» path was `onTapGesture` on a `Text` — invisible to keyboard/focus. | Real plain `Button` with tooltip; joins the Tab order. |

### Status

| # | Finding | Fix |
|---|---|---|
| St1 | `StatusBanner` (non-interactive) wore the same filled capsule as the interactive `PermissionBannerRow` — status dressed as a button (PRINCIPLES §5 conflict too). | Quiet icon + footnote row; the pill stays reserved for clickable banners. |
| St2 | Capacity ring's 0.8–1.0 band painted the reserved accent color as a status zone (PRINCIPLES §7 conflict). | Whole fits-today range uses the success color; the fill fraction carries «how full», color carries only ok/tight/over. |
| St3 | High-priority and overdue rendered as two identical red dots; Reduce Motion removed the only differentiator (pulse). | High priority is now an `exclamationmark.circle.fill` glyph — shape differentiates, not color/motion. |
| St4 | Ring's `accessibilityValue` dropped the qualitative verdict; iCloud sync warning was tint-only; in-progress spinner unlabeled. | Verdict appended («… — Over capacity»); status glyph flips to `exclamationmark.icloud` on warning; spinner labeled «Syncing». |

## Deferred (needs product decision / larger change)

- **Settings `Form(.grouped)` migration.** Only `GeneralTabView` uses the
  native grouped form; eight tabs still stack full-width `SettingsPlatter`
  cards (HIG boxes: a box near the container's size stops communicating
  grouping; also PRINCIPLES §2). The `GeneralTabView` pattern is the
  template — migrate tab-by-tab with build+screenshot passes.
- **Full-screen takeover scope.** Every reminder blacks out the screen at
  `.screenSaver` level. HIG alerts want takeovers rare; consider reserving
  it for joinable/imminent meetings and using the join-ribbon style
  otherwise, or a setting.
- **Unsaved-changes confirmation on edit forms.** Cancel/Esc discards
  edits silently; `hasUnsavedChanges` also misses date/duration/reminder
  changes. Wants a dirty-check against the source + «Discard Changes?»
  dialog.
- **Palette ↑/↓ reliability.** `.onKeyPress` sits on the card while focus
  lives in the TextField; move key handling onto the field (`.onMoveCommand`).
- **Remaining raw `.subheadline` uses** (~30 sites in Settings/Palette/
  EventDetail) → migrate to `DS.Typography.row` opportunistically.
- **Determinate sync progress** for Reminders import (item count is known).
- **Toast pacing** — fixed 2.5 s regardless of message length; no
  hover-to-pause.

## Verified compliant (don't regress)

- `ContentUnavailableView` empty states; flat unboxed rows; single
  hairline idiom; one 16pt content margin (layout).
- Destructive actions separated + bottom-anchored with roles; recurring
  delete confirmation with specific verbs (menus/presentation).
- Back button = previous screen's name, top-leading; palette keyboard
  loop (navigation).
- Backdrop legibility system (WCAG-checked scrims, accent adaptation);
  Reduce-Motion gates on every infinite pulse + the disintegration
  effect (presentation/status).
- `RecurrencePickerView` (standard Picker/Stepper/DatePicker) and
  `ColorDotButton` (focusable, non-color selection signal) as the
  input-pattern references (selection & input).
