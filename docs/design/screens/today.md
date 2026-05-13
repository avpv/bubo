# Today popover

> The main surface — what opens when the user clicks the menu-bar owl.
> Answers «what's now», «what's next», and «is the rest of the day
> alright» in one glance, then offers one primary action if not.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| T1 | Глянул на menubar | Понять «что сейчас / что дальше» без открытия | Не отвлекаться |
| T2 | Открыл popover | Прочитать состояние дня за одно движение глаз | Решить, лезть ли глубже |
| T3 | Вижу конфликт или перегруз | Получить ровно одно primary-действие | Запустить решение без раздумий |
| T4 | Скоро встреча | Joins без поиска ссылки | Не опоздать |
| T5 | Появилось событие | Добавить его за <5 с | Не забыть |
| T6 | Хочу посмотреть другой день | Перемотать таймлайн | Спланировать вперёд / разобрать прошлое |

## 2. Current state

### Files

- **Root composition** — `Bubo/Presentation/Views/MenuBar/MenuBarView.swift:134–157`
- **Main content wrapper** — `Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift:101–141`
- **Timeline / event list** — `Bubo/Presentation/Views/MenuBar/MenuBarView+Timeline.swift:1–163` and `EventList` invocation at `MenuBarView+MainContent.swift:322–325`
- **World clock strip** — `WorldClockStripView`, mounted at `MenuBarView+MainContent.swift:165–169`
- **Color filter** — `Bubo/Presentation/Views/Components/Picker/ColorFilterBar.swift:1–70`
- **Smart actions** — `Bubo/Presentation/Views/Components/Backlog/SmartActionsBar.swift` → `SmartActions.swift:1–138`
- **Now/Next status line** — `MenuBarView+MainContent.swift:272–279`
- **Footer** — `Bubo/Presentation/Views/Components/Common/FooterActions.swift:1–120`

### Anatomy today

Top-down:

1. `PopoverHeader` — title + day-nav (prev / today / next) + search
2. `WorldClockStripView` (conditional — only if `settings.worldClockCityIDs` non-empty)
3. `ColorFilterBar` (SHOW + dots + free-slot + clear-all)
4. `SmartActionsBar` — diagnosis + action, with inline scenario picker (`SmartActions.swift:363–400`)
5. `NowNextLine` — «in 12 min · Design review» + overdue badge
6. `EventList` — the actual timeline for the current day
7. `FooterActions` — Add (menu: New Event / New Task) · Tasks · More (Refresh / Settings / Quit)

### Known failures

- **F1 (T1, T6).** Timeline shows **one day at a time**. To see
  tomorrow you must press `>`. The user holds the day in their head,
  not the screen. Mockup stacks days; we don't.
- **F2 (T2).** Free slots are inert visuals between events. Mockup
  shows each as a drop-target with `+` affordance — the slot is also
  a thing you can act on.
- **F3 (T3).** `SmartActionsBar` competes with the colour filter and
  the world clock for the top band. Three optional-but-loud bars
  before the timeline. Violates `PRINCIPLES.md §1`.
- **F4 (T6).** Working-hours window is implicit. The user must read
  start/end from settings; the timeline doesn't visualise where the
  working window actually is.
- **F5 (T4).** Join affordance exists on event rows but is not
  visually prioritised over other meta on the row.
- **F6 (T1).** No way to see day-level density without opening the
  popover. Menu-bar owl carries no glanceable load indicator yet
  (separate `menubar-density.md`).

## 3. Target design

- **Mockup**: `ui_kits/index2.html:1530–1836`

### Anatomy (target)

```
┌───────────────────────────────────────────┐
│ Tuesday, 6 May          ‹ Today ›  🔍     │ topbar
│ 5 events · next in 5 h 18 min             │
├───────────────────────────────────────────┤
│ UTC 03:30 ·  Moscow 06:30  ·  Belgrade 05 │ city-row (scrollable, fades)
├───────────────────────────────────────────┤
│ ⚡ Reschedule conflict · Start Pomodoro …│ smart-actions chip-row
├───────────────────────────────────────────┤
│ SHOW  🔴 🟠 🟡 🟢 🔵 🟣 🌸 ⚪              │ color-filter dot rail
├───────────────────────────────────────────┤
│ ── Yesterday · Mon, 5 May ─────  3 events │ day-block (collapsible)
│ │  sunrise ─── Working hours start 09:00 ⤴│
│ │  10:00–11:00 │ Sprint planning           │ event row
│ │  ...                                     │
│ │  sunset  ─── Working hours end   19:30 ⤵│
│ ── Today · Tue, 6 May ──────────  5 events│ day-block (open by default)
│ │  09:00 ⤴                                │
│ │  9:30–10:00  │ Stand-up                  │
│ │  10:30–11:00 │ Auth bug — round 1    Now │
│ │  ── NOW · 10:48 ────────────────         │ now-line
│ │  11:00–11:45 │ Design review  in 12 min  │
│ │              │ Zoom · M·A·+2     [Join] │
│ │  Free · 45 min  11:45–12:30       [ + ]  │ free-slot (drop-target)
│ │  ...                                     │
│ │  23:00 ⤵                                │
│ ── Tomorrow · Wed, 7 May ───────  2 events│
│   ...                                     │
│ ⌄ Load more days                          │
├───────────────────────────────────────────┤
│ [+ Add event]              Tasks    ⋯     │ footer
└───────────────────────────────────────────┘
```

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Day axis | one day, nav buttons | multi-day stacked scroll, infinite-loader |
| Working hours | implicit (settings) | explicit bookends with sunrise/sunset icons |
| Free slots | inert visual | drop-target with `+` button |
| NOW marker | exists | unchanged, but inside multi-day stream |
| Smart-actions | bar with N chips | unchanged shape, but **one** prominent + others quiet |
| Color filter | toolbar | dot-rail with SHOW label (denser, masks edges) |
| World clock | strip if enabled | scrollable chips with fade-mask, `data-here` accent on home |
| Scenario picker | inline dots (`SmartActions.swift:363–400`) | extracted to its own surface (see `scenario-picker.md`); inline stays as a status read-out, not a switcher |
| Footer | Add menu / Tasks / More | unchanged structure, `Add` stays primary, the rest quiet |
| Day-block collapse | n/a | each `day-block` can collapse to a one-line summary |

## 4. Acceptance criteria

### Multi-day timeline

- [ ] `EventList` becomes a list of `DayBlock` views inside a single
      `ScrollView`. Each `DayBlock` renders its own header
      («Yesterday · Mon, 5 May · 3 events»), working-hours bookends,
      and event rows
- [ ] On open, scroll position is anchored to **today's first
      upcoming event** (or NOW marker if mid-day)
- [ ] `Load more days` button at the bottom adds 7 forward days. A
      symmetric «Load earlier» appears at the top after first scroll
- [ ] Day-nav buttons in the topbar (`‹ ›`) jump-scroll to the
      previous / next day. `Today` button jumps to today's first
      upcoming event

### Working-hours bookends

- [ ] Each `DayBlock` opens with `WorkingHoursStart` line (sunrise
      icon + time + ↕ controls) and closes with `WorkingHoursEnd`
      (sunset icon + time + ↕ controls)
- [ ] Tapping the time inline-edits via stepper, same write path as
      settings (so the change persists globally)

### Free slots

- [ ] `FreeSlot` row becomes an interactive drop-target. Trailing
      `+` button opens a quick menu: `Schedule a task… · Add event…`
- [ ] Dragging a `BacklogTask` over a free slot highlights it; drop
      commits the schedule through `OptimizerService.scheduleTask`
      (or equivalent path) so undo bookkeeping is preserved

### Top band density

- [ ] `WorldClockStripView`, `ColorFilterBar`, `SmartActionsBar`
      keep their slots but only one of them may render a
      **prominent** chip at a time. `SmartActionsBar` wins when it
      has a hard problem to surface; otherwise it goes calm
- [ ] `ColorFilterBar` switches from current toolbar style to the
      dot-rail style in the mockup (denser, masked edges)
- [ ] World-clock home city carries the accent state
      (`data-here="true"`); offset shown for non-home cities

### Smart-actions

- [ ] One prominent action at a time (`PRINCIPLES.md §1`). If the
      optimizer has a conflict and a soft suggestion, the conflict
      wins
- [ ] Remove inline scenario-picker dots from `SmartActions.swift`;
      replace with «Plan ready · view N options ▸» that pushes
      `ScenarioPickerView` (see `scenario-picker.md`)

### Event row

- [ ] Reduce trailing meta on the row: keep `Join` (for video
      meetings) prominent; everything else (location, count,
      Pomodoro round) lives in the `meta-stack`
- [ ] `Now` badge stays — orange filled

### Footer

- [ ] Unchanged structure. `Add` stays primary (filled, accent).
      `Tasks` and `⋯` stay quiet on the right

## 5. Out of scope

- **Menu-bar density bar.** Separate doc `menubar-density.md`. The
  popover's job is what happens after the click; the density bar
  serves T1.
- **Quick Capture (⌃⇧⌘Space).** Solves T5 outside the popover. Its
  own doc.
- **Search.** The 🔍 icon in the topbar is a stub for a future
  full-day-range search surface. Mock now, ship later.
- **Drag from external apps.** Dropping a Notion task / mail thread
  onto a free slot is a great J1/T5 extension, but it's not the
  first PR — let the in-app drag prove the pattern.
- **Day-block collapse to one-line summary.** Useful when looking at
  10 days of history, premature now. Earn it back once multi-day
  scroll ships.
- **Fullscreen meeting alert.** Out of scope for the popover surface;
  separate doc.
