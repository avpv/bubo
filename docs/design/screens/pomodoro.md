# Pomodoro mini-window

> A small pinned floating window that lives during a focus session.
> The ring tells you how much time is left; the task line tells you
> what you're doing; the buttons let you skip / pause / stop without
> opening the popover.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| P1 | Запустил Pomodoro | Видеть таймер не отвлекаясь | Знать сколько осталось без проверки часов |
| P2 | Делаю задачу | Не сомневаться, что я внутри сессии | Не забыть включить |
| P3 | Нужна пауза | Pause за один клик | Не возиться с настройками |
| P4 | Закончил раунд раньше | Skip к перерыву | Не тянуть оставшиеся 3 минуты впустую |
| P5 | Сделал 2 круга | Видеть статистику дня | Получить feedback от системы |
| P6 | Хочу сменить задачу | Поменять без выхода | Не терять inertia |

## 2. Current state

### Files

- **View** — `Bubo/Presentation/Views/Timer/TimerScreenView.swift:1–695`
- **Pinned window mount** — `Bubo/Composition/AppDelegate/AppDelegate+PinnedTimer.swift:1–86`
- **History / learning** — `Bubo/Application/Pomodoro/PomodoroHistoryService.swift:1–124`

### Anatomy today

`TimerScreenView` — full Pomodoro display:

1. Hero ring with real-time progress (`TimelineView`-backed)
2. Phase badges (Work / Short Break / Long Break)
3. Round dots indicating session position
4. Session metadata (date, time, location)
5. Scrub-able ring: horizontal drag adjusts end-date; vertical
   drag pauses

When pinned (`Pin` button), AppDelegate creates a floating
`NSPanel` at top-right (DS.Popover.width × timerHeight), with
glass-material backdrop. `PomodoroHistoryService` records
session outcomes (work/break minutes, rounds, hour-of-day) for
future config bias.

### Known failures

- **F1 (P1).** View is 695 lines — too rich for a glance-mode
  pinned window. It does session admin + scrubbing + history,
  and **also** acts as the «during focus» surface. Two jobs in
  one
- **F2 (P2).** Phase badge reads «Work» / «Short Break», but
  mockup is more specific: «`Focus · 1 of 4`» (mode + round in
  one line). Reads as «I am in round 1 of a 4-round set»
- **F3 (P3).** Pause is one of many gestures (vertical drag).
  Discoverable? Less so. Mockup puts a Pause filled-orange-
  gradient button dead-centre — single target, big
- **F4 (P4).** Skip lives in the buttons row at the bottom
  but ranks visually equal to pause. Mockup keeps it ghost
  (skip is rarer than pause)
- **F5 (P5).** Stats row not visible in current pinned mini.
  Mockup adds a foot: «`🔥 2 done today · ☕ break in 18 m`»
- **F6 (P6).** «Change task» affordance not on the pinned
  window. Mockup shows a `chevron-down` next to the task
  title, opening a quick picker

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2339–2381`

### Anatomy (target mini-window)

```
┌──────────────────────────────────┐
│ ✕      FOCUS · 1 of 4        ⚙   │ topbar
│                                  │
│         ╭─────────╮              │
│         │         │              │
│         │  18:42  │  140×140 ring│
│         │  LEFT   │              │
│         ╰─────────╯              │
│                                  │
│ ┌────────────────────────────┐   │
│ │ ● Group snippets — fix scr ▾│  │ task pill
│ └────────────────────────────┘   │
│                                  │
│         ⏭        ⏸        ⏹      │ controls
│                                  │
│        🔥 2 done · ☕ break 18m   │ foot stats
└──────────────────────────────────┘
```

### Key visual elements

- **Topbar**: 8 / 10 / 4 pt padding. `✕` icon-btn left ·
  `FOCUS · 1 of 4` 11 pt 600 uppercase in `system-orange`,
  tracking `.04em` · `⚙` icon-btn right
- **Ring**: 140 × 140 SVG. 6 pt stroke. Background ring at
  `white 8%`; foreground at `linearGradient(system-orange →
  system-pink)`. Dasharray-based progress, `−90°` rotation.
  Time text inside at 26 pt 700 mono tabular-nums; sub-label
  `LEFT` at 10 pt 500 uppercase tracking
- **Task pill**: 8 / 12 pt padding, 8 pt radius, `fg-1 5%`
  background, 0.5 pt border. Inside: 8 pt `cal-dot` (task's
  calendar colour) · title (12.5 pt 600 rounded, ellipsis) ·
  trailing chevron icon-btn for quick task switch
- **Controls**: 14 pt gap, centred. `⏭` ghost (36 pt circle,
  `fg-1 6%` background) · `⏸` primary (52 pt circle,
  `system-orange → system-pink` gradient, 4 / 12 pt accent-
  shadow) · `⏹` ghost
- **Foot stats**: centred 14 pt gap, 10.5 pt 600 rounded,
  `fg-3`. Format: «`🔥 2 done today`» + «`☕ break in 18 m`»

### Diff vs current

| | Current (TimerScreenView) | Target (Pomodoro mini) |
|---|---|---|
| Role | session admin + during-focus | during-focus only; admin lives in popover |
| Lines of view | 695 | ~200 target |
| Ring | scrubable (drag = adjust / pause) | display-only; pause is its own button |
| Phase badge | «Work / Short Break» | «`FOCUS · N of M`» |
| Pause | gesture (vertical drag) | filled-gradient round button, dead-centre |
| Task switch | absent on pinned | trailing chevron on task pill |
| Stats foot | absent | done-today + next-break |
| Settings | inline | trailing gear icon-btn |

## 4. Acceptance criteria

### Mini-window separation

- [ ] Split `TimerScreenView` into:
      - `PomodoroMiniView` — the pinned during-focus surface
        described above (~200 lines)
      - `PomodoroAdminView` — the session-admin surface
        (start a session, configure rounds, see history),
        opens from `PomodoroMiniView`'s `⚙` button or from
        the popover `⋯`-menu
- [ ] `AppDelegate+PinnedTimer` mounts `PomodoroMiniView`,
      not the full view

### Ring

- [ ] 140 × 140 SVG, 6 pt stroke. Foreground gradient
      `system-orange → system-pink`. Background `white 8%`
- [ ] Display-only (no scrub gestures in mini)
- [ ] Time text 26 pt 700 mono tabular-nums; format `MM:SS`
- [ ] `LEFT` sub-label 10 pt 500 uppercase `fg-3` tracking
      `.04em`

### Topbar

- [ ] Phase + round label: «`FOCUS · N of M`» (work) /
      «`SHORT BREAK · N of M`» / «`LONG BREAK · N of M`»
- [ ] All-caps `system-orange` in focus phase; `accent` in
      break phase. 11 pt 600 rounded, tracking `.04em`

### Task pill

- [ ] Bound to the active session's task (if any). If session
      has no task, hide the pill and shrink window height
- [ ] Calendar-coloured 8 pt dot + task title + chevron
- [ ] Tap on pill / chevron opens a task picker overlay
      (search-as-you-type from `BacklogService.pending`,
      single-tap to switch). On switch, current session's
      task is updated mid-flight (no restart)

### Controls

- [ ] `⏭ Skip` — ghost 36 pt. Advances to the next phase
      (work → break, break → next work)
- [ ] `⏸ Pause / ▶ Resume` — primary 52 pt with gradient and
      accent-shadow. Toggles `pause`. Glyph changes; gradient
      stays
- [ ] `⏹ Stop` — ghost 36 pt. Confirms via undo toast
      («Session stopped · Undo»). On stop, the mini-window
      auto-closes after 1 s

### Stats foot

- [ ] Two stats: «`🔥 N done today`» (count from
      `PomodoroHistoryService.todaySessionCount`),
      «`☕ break in <MM:SS>`» (countdown to next break inside
      current focus phase). Hidden during break phases
- [ ] Centred. 10.5 pt 600 rounded `fg-3`. 14 pt gap

### Window chrome

- [ ] 280 pt width, height auto from content (~260 pt with
      task pill, ~220 pt without)
- [ ] Pinned top-right by default; remember last drag
      position per-display (same pattern as `quick-capture.md`)
- [ ] On `Reduce Motion`, ring re-renders only on minute
      changes (still accurate within ±1 s of the second
      visualisation), not per-second

### Lifecycle

- [ ] Mini auto-opens when `PomodoroService.start()` fires —
      no separate Pin step
- [ ] User can opt-out per-session via a checkbox in
      `PomodoroAdminView`: «Don't pin during this session»
- [ ] Closes on session end with a 600 ms cross-fade

## 5. Out of scope

- **Drag-to-scrub** on the ring. The mini is glance + control,
  not edit. Scrub lives in admin
- **Per-task Pomodoro round counts** («3 of 5 for this task»)
  vs «3 of 5 for this session». Mockup uses session-scope;
  task-scope is a separate model decision
- **Focus / break sound effects.** macOS provides system
  sounds; Bubo can configure them, but choosing them is the
  admin surface's job
- **Calendar integration during focus** («skip if a meeting
  is in 5 min»). Worth doing but lives in
  `PomodoroService` logic, not the UI
- **Multi-monitor mini placement policy.** Same as
  `meeting-alert.md` — defer
- **History view** (last N sessions). Lives in
  `PomodoroAdminView`, not the mini
