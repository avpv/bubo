# Event / task editor

> The «I know I want this, give me all the levers» surface. Where a
> raw thought becomes a structured event or task — title, time, repeat,
> reminders, Pomodoro flag, calendar lane, notes. Three flows today,
> one visual language tomorrow.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| E1 | Хочу занести встречу | Ввести название + время + ссылку | Получить полноценное событие в одном проходе |
| E2 | Встреча повторяющаяся | Задать правило повторения | Не вводить каждую неделю |
| E3 | Часто пропускаю напоминания | Настроить стек (30/10/2 min) | Сигнал не один, а лестница |
| E4 | Это focus-блок | Пометить Pomodoro-режимом | Оптимизатор и таймер знали |
| E5 | Событие приватное | Local-only toggle | Коллеги не увидели в общем календаре |
| E6 | Длинное описание / агенда | Notes textarea | Открыть прямо из алерта |
| E7 | Передумал | Cancel за один клик | Не плодить мусорные черновики |

## 2. Current state

### Files

Three separate forms with overlapping shape:

- **`AddEventView`** — `Bubo/Presentation/Views/Event/AddEventView.swift:1–654`
  Full calendar event form. Title · location/URL · start/end pickers ·
  recurrence rules · stacked custom reminders · Pomodoro flag (gated
  to events ≥ 25 min) · calendar picker (new mode) · colour dots ·
  context field · location with emoji picker · notes · «More
  options» collapse. Supports new + edit modes; external-calendar
  events render read-only title/date but allow local overrides
  (colour, context, reminders)
- **`NewTaskView`** — `Bubo/Presentation/Views/Event/NewTaskView.swift:1–582`
  Compact task creation: title / notes / URL up top; date / urgent /
  duration in middle; «More options» collapse below. Sits between
  Quick Capture and the full task editor
- **`EditTaskView`** — `Bubo/Presentation/Views/Event/EditTaskView.swift:1–814`
  Full task editor. See `task-details.md` §2 — this view is the
  «old» editing surface being replaced by Task Details

Shared chrome: `PopoverHeader` + `sectionBlock` platter pattern.

### Anatomy today

`AddEventView` and `NewTaskView` look related but use **different
field renderers** internally (each picker / toggle / chip rebuilt
per view). The mockup proposes one row pattern (`settings-row`:
icon + label + hint + control) that subsumes them both.

### Known failures

- **F1 (E1).** Title input has no visual prominence — sits at the
  same weight as field labels below it. Mockup makes the title a
  16 pt 700 hero, location a 12.5 pt 500 underline
- **F2 (E2, E3, E4, E5).** Per-field renderers diverge across the
  three views. A user opening Add-Event then New-Task sees
  «different products» despite Bubo being one
- **F3 (E6).** Notes lives inside «More options» collapse. For
  events with linked Zoom URL or pasted agenda, the notes are
  the **point** of the event row, not a footnote
- **F4 (E7).** Cancel is a footer button next to Save (both 12 pt
  500). Mockup elevates Save to a filled-accent pill on the
  right and demotes Cancel to a 600-weight `fg-3` plain link on
  the left — proper hierarchy
- **F5 (general).** Three separate code paths for what users
  experience as «edit this thing». Maintenance cost: a bug fix
  often needs three patches

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2746–2799` (the «New event»
  full editor)

### Anatomy (target)

```
┌────────────────────────────────────────────────────┐
│ Cancel               New event              [Save] │ topbar
├────────────────────────────────────────────────────┤
│ Deep work · Ad traffic clean-up                    │ title (hero)
│ Location or video URL                              │ subline
├────────────────────────────────────────────────────┤
│ 📅 Date                  Tue, May 12 · today       │
│                          14:00 — 15:00             │ settings-row
│ 🔁 Repeat                Weekly on Tue, Thu · ∞  ›  │
│ 🔔 Reminders             Stacked: 30 / 10 / 2  ›   │
│ 🍅 Pomodoro              Auto · 50/10 · 1 round 🟢 │ (toggle on)
│ 🙈 Local-only            Stored on this Mac    🟢  │ (toggle on)
│ 🎨 Calendar              🔵 Local             ›    │
├────────────────────────────────────────────────────┤
│ Notes…                                             │ textarea
│                                                    │
└────────────────────────────────────────────────────┘
```

### Key visual elements

- **Topbar**: `Cancel` (left, 12 pt 600 `fg-3`) · «New event»
  (centred, 13 pt 700) · `Save` (right, filled accent pill,
  24 pt height, 12 pt 700, `accent 14%` background)
- **Hero block**: `12 / 14 / 4 pt` padding. Title input —
  16 pt 700 rounded, `letter-spacing: -0.01em`. Location/URL
  input — 12.5 pt 500 `fg-3`, with a 0.5 pt bottom border
  separator
- **Settings-row** (shared with Settings popover): 8 / 14 pt
  padding, 10 pt gap. Layout: icon (13 pt, `fg-3` or
  semantic-coloured) · label · hint (sub-line, 11 pt 400) ·
  control or value or chevron
- **Notes**: 10 / 14 pt padding, 0.5 pt top separator,
  `TextEditor` 12.5 pt 400 rounded, 2 rows min height

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Surfaces | 3 separate Views (`AddEventView`, `NewTaskView`, `EditTaskView`) | 1 view + 2 thin wrappers: `EntityEditorView<Kind>` |
| Title hierarchy | sibling to fields | hero — 16 pt 700, top of view |
| Field renderer | per-view custom | shared `SettingsRow` component |
| Save / Cancel | equal-weight footer | filled-accent Save (topbar right), quiet Cancel (topbar left) |
| Pomodoro flag | gated by duration (≥ 25 min) | always visible; gates to «recommended» when duration would normally fire it |
| Calendar picker | inline chip grid | `SettingsRow` with disclosure |
| Notes | inside «More options» | always visible at the bottom |

## 4. Acceptance criteria

### Architecture: one editor, two kinds

- [ ] New SwiftUI generic view at
      `Bubo/Presentation/Views/Event/EntityEditorView.swift`
- [ ] Parameterised by `EditableKind { case event, task }`. The
      union of fields covers both:
      - shared: title · location/URL · notes · colour-tag ·
        context · recurrence
      - event-only: start+end pickers · reminder stack ·
        Pomodoro flag · local-only
      - task-only: duration · priority · deadline · preferred
        period · story points · subtasks · tags · dependencies
- [ ] Each `SettingsRow` is conditionally rendered based on
      kind; common ones use the same view code
- [ ] Wrappers stay for source compatibility:
      `NewEventView { EntityEditorView(.event, mode: .new) }`,
      `EditEventView { EntityEditorView(.event, mode: .edit(id)) }`,
      same for tasks. Old call sites compile unchanged

### Topbar

- [ ] `Cancel` on the left — plain icon-btn style, 12 pt 600
      `fg-3`, no border, hover lightens `fg-2`
- [ ] Title centred — varies by `(kind, mode)`:
      `New event` / `Edit event` / `New task` / `Edit task`
- [ ] `Save` on the right — filled-accent pill, 24 pt height,
      `accent 14%` background, 12 pt 700 accent text. Disabled
      (`opacity: 0.4`) until the form has any change

### Hero block

- [ ] Title input: 16 pt 700 rounded, transparent background,
      no border, accent caret. `text-wrap: pretty`, max-width
      = popover width − 28 pt
- [ ] Location/URL subline: 12.5 pt 500 `fg-3`. 0.5 pt bottom
      border separator. URL detection: pasting a Zoom / Meet /
      Teams URL auto-tags `event.conferencingPlatform` so the
      meeting alert and join ribbon use platform-aware labels
      (see `meeting-alert.md` §4)

### Shared `SettingsRow` component

- [ ] New file `Bubo/Presentation/Views/Components/Common/SettingsRow.swift`
- [ ] Init: `SettingsRow(icon: SymbolName, iconTint: Color?,
      label: String, hint: String? = nil, control: () -> Content)`
- [ ] Layout: 8 / 14 pt padding, 10 pt gap, hint as sub-line
      (11 pt 400 `fg-3`)
- [ ] Reused in `EntityEditorView`, Settings tabs (see
      `settings.md`), and Intent composer rows

### Pomodoro row

- [ ] Always rendered (no duration gate). When duration < 25 min,
      the toggle defaults to off and the hint reads «Auto · not
      recommended for short events»; user can still flip it on
      manually
- [ ] Hint when on: «`Auto · Deep Work · 50 / 10 · N rounds`»
      with current preset; tap the row body opens the Pomodoro
      preset picker

### Local-only row

- [ ] Toggle. Hint: «Stored on this Mac only · invisible to
      coworkers»
- [ ] Default ON for tasks (private by nature); default OFF for
      events (most are shared)

### Calendar row

- [ ] Disclosure-chevron row. Trailing value: 8 pt colour dot +
      calendar name + chevron
- [ ] Tap pushes a calendar picker that lists user's configured
      calendar sources (iCloud / Google / Exchange / CalDAV /
      Bubo Local). Mirrors the Settings → Calendars list

### Notes

- [ ] `TextEditor` always visible at the bottom. 2 rows min,
      grows to ~6 rows max before scrolling
- [ ] Markdown render-on-blur stays out of scope (see
      `task-details.md` §5); first PR is plain-text

### Cancel / Save behaviour

- [ ] `Cancel` — if form has unsaved changes, confirm via
      `confirmationDialog` (Birman: branching destructive,
      `PRINCIPLES.md §4`). If pristine, pop immediately
- [ ] `Save` — on new, creates and pops back to source; on edit,
      writes through and pops. Undo toast for new-creates

## 5. Out of scope

- **Migrating `EditTaskView` to this view.** Task Details surface
  (see `task-details.md`) is the inspect-and-act surface; the
  editor view here is for create-new + edit-fields. They coexist;
  `EditTaskView` itself becomes the task-mode of
  `EntityEditorView` in a later PR
- **Inline conferencing-URL preview.** Pasting a Zoom URL could
  pull a preview card. Defer
- **Attachments / file picker.** Not in mockup
- **Recurring-event «edit this occurrence vs entire series».**
  Existing dialog from `AddEventView` continues to work and is
  the canonical branching-destructive moment (`PRINCIPLES.md §4`)
- **Per-attendee invite tracking.** External calendar concern
- **Markdown editor for notes.** See `task-details.md` §5
- **Emoji picker for location.** Currently lives inside
  `AddEventView`. Keep it as a follow-up — useful but
  ornamental
