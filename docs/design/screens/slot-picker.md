# Slot picker

> Picks a time for **one** task. Direct manipulation when the user
> knows the task and is choosing the slot; the inverse of the
> existing slot-anchored picker, where the user knows the slot and is
> choosing tasks to fill it.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| L1 | Решил, что задача делается сегодня | Поставить её на конкретное время | Календарь её увидел |
| L2 | У меня есть привычное окно для этого типа задач | Найти ближайшее такое окно | Не считать руками |
| L3 | Все хорошие окна заняты | Увидеть конфликты и решить, ломать ли | Сделать осознанный выбор |
| L4 | Слот не подходит | Сразу попробовать «завтра 14:00» или «+1d» | Не открывать новый экран |
| L5 | Опции исчерпаны на сегодня | Перейти к завтра в той же логике | Не выпадать из flow |

## 2. Current state

### Files

- **Existing picker** — `Bubo/Presentation/Views/Components/Slot/SlotPickerPopover.swift:1–952`
- **Ranker** — `TimelineSlotRanker` (referenced from the picker)
- **Service entry** — `OptimizerService.scheduleTask(_:)` and related
  per-task scope calls
- **Wiring point** — `BacklogView.onScheduleTask`,
  `BacklogFullscreenView.onScheduleTask` callbacks

### Anatomy today

The existing `SlotPickerPopover` is **slot-anchored**, not
task-anchored:

1. Slot header (`:432–474`) — `HH:mm–HH:mm · Xh`, queued count,
   remaining duration, Done button
2. Input field autofocused (`:323–328`) — type new title, Enter
   submits
3. Queued-creates chip strip (`:336–338, 481–523`) — pills for
   typed-then-Entered tasks
4. Filter chips row (`:348–351, 675–819`) — smart / project /
   colour
5. Candidate list (`:357–371, 554–574`) — ranked existing tasks,
   checkmark when queued, «won't fit» badge
6. Fullscreen escape (`:378–401`) — routes to backlog editor
7. Esc/click-outside dismiss (`:410–422`) — auto-commits queued

### Known failures

- **F1 (L1).** Inverted direction. The most-frequent task-side flow
  («I have this task, when do I do it?») has no first-class
  picker. The user starts at a slot, not at a task.
- **F2 (L2).** No natural-language search input («tomorrow 2 pm»,
  «+1d»). The user must visually scan the candidate list. The
  existing picker's input creates **new tasks**, not searches for
  slots.
- **F3 (L3).** Conflicts aren't surfaced as picks. The candidate
  list shows free windows; ranges that overlap existing events
  aren't presented as «displace this» options.
- **F4 (L4 / L5).** Cross-day flow is implicit. Tomorrow doesn't
  appear in the list unless the slot itself is multi-day. The user
  has to close, reopen, navigate.
- **F5 (general).** The current view conflates two jobs into one
  surface (capture + slot-fill). Both are useful, but the
  task-anchored picker the mockup proposes is closer to the
  «Schedule» button users see in Backlog, Task details, and the
  bulk-action bar.

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2277–2337`

The mockup is a **task-anchored** picker. Rename and refocus:
keep the existing `SlotPickerPopover` for the slot-anchored flow
(opened by `+` on a free slot in Today timeline; see `today.md`),
and add a **new** `TaskSlotPickerView` for the task-anchored flow.

### Anatomy (target — task-anchored)

```
┌───────────────────────────────────────────┐
│ ● Group snippets — fix screen   1h  [Done]│ task line + Done
│ Today · 5 h 18 min free                   │
├─────────▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱──────────────── │ rank-progress bar (26 %)
├───────────────────────────────────────────┤
│ 🔍 Find time…  type 'tomorrow 2pm' or '+1d'│ NL input
├───────────────────────────────────────────┤
│ TODAY · BEST FITS                         │ section
│ ✓ 09:30 — 10:30   free 1 h   before standup│ row (chosen)
│ ○ 11:15 — 12:15   free 1 h 45 m            │
│ ○ 16:30 — 17:30   free 2 h    after deep   │
│                                           │
│ CONFLICTS SHOWN                           │
│ ○ 14:00 — 15:00   ⚠ Deep work             │ dim, conflict badge
│                                           │
│ TOMORROW                                  │
│ ○ Wed · 09:00 — 10:00    free             │
│ ○ Wed · 13:30 — 14:30    free             │
├───────────────────────────────────────────┤
│ ⚙ Smart slots · skip lunch · 25 m min     │ foot
└───────────────────────────────────────────┘
```

### Anatomy (target — slot-anchored, current shape kept)

Keep the existing `SlotPickerPopover` for the case where the user
clicks `+` on a free slot in the Today timeline. Its job is to
fill **that** slot. Tidy it but don't refactor in the same PR.

### Diff vs current

| | Current (slot-anchored) | Target task-anchored |
|---|------|------|
| Anchor | a slot, fill with tasks | a task, find a slot |
| Input | creates new tasks | searches slots («tomorrow 2 pm») |
| Candidate list | tasks, ranked by fit | slots, ranked by fit |
| Conflicts | n/a | shown as picks with «overrides this event» |
| Cross-day | not in this picker | section headers for Today / Tomorrow / This week |
| Anchor row | the slot bar | the task line |

## 4. Acceptance criteria

### Naming clarity

- [ ] Rename existing `SlotPickerPopover` to `SlotFillPopover`
      (only when anchored to a slot). Move file to
      `…/Components/Slot/SlotFillPopover.swift`. Update callers
- [ ] Create new view `Bubo/Presentation/Views/Backlog/TaskSlotPickerView.swift`
      for the task-anchored flow

### Task line header

- [ ] Colour dot (`task.colorTag` or fallback) · title · duration
- [ ] Right: `[Done]` button — primary if `picked != nil`,
      otherwise quiet/cancel-coloured

### Free-time chart

- [ ] One-line summary: «Today · `<free>` free» (use
      `DS.formatMinutes`)
- [ ] Below: thin horizontal bar (4 pt high) representing the
      day; chosen slot fills a proportional segment. Re-uses
      `ScenarioStrip` colour conventions

### Natural-language input

- [ ] Single input field with placeholder
      `Find time… type 'tomorrow 2pm' or '+1d'`
- [ ] Parser supports the small grammar:
      - relative: `+1d`, `+30m`, `next mon`
      - absolute: `tomorrow 14:00`, `wed 9am`, `15:30`
      - keyword: `morning`, `afternoon`, `evening`, `tonight`
- [ ] As the user types, the candidate list filters; first match
      becomes the chosen row

### Candidate list

- [ ] Three section headers, conditional:
      - `TODAY · BEST FITS` — ranked by `TimelineSlotRanker`
        score
      - `CONFLICTS SHOWN` — only if no good fits today and user
        explicitly toggles «show conflicts» (Smart slots setting)
        or types into the NL input a slot that conflicts
      - `TOMORROW` — fallback when today is full
- [ ] Each row: chosen-checkmark · time range · `free Xh` badge
      OR `⚠ Conflict name` badge (when displacing)
- [ ] Optional descriptor («before standup», «after deep work») —
      shown when the ranker found a semantic landmark
- [ ] Tap a row → it becomes the chosen one; `Done` becomes
      primary

### Foot bar

- [ ] `⚙ Smart slots` — opens a sheet to edit Smart-slot
      preferences: skip-lunch toggle, minimum slot length,
      ignored cohorts. Settings persist via
      `OptimizerService.workingHours` / `workingDays` and a new
      `smartSlotPrefs` sub-record
- [ ] Closed by default; reopening the picker remembers the last
      values

### Confirm path

- [ ] `Done` calls `OptimizerService.schedulePinnedTask(_:at:)`
      (new method) which commits a hard-pinned scenario via the
      same path as the user dragging a task onto a slot. Lands
      with undo toast
- [ ] Esc cancels with no changes; click-outside cancels with no
      changes (no auto-commit on this flow — the user must press
      `Done`)

### Reuse

- [ ] `TimelineSlotRanker` is reused as-is for the «BEST FITS»
      ordering. Cross-day candidates require expanding its scope
      from one day to N — add a `daysAhead` parameter

## 5. Out of scope

- **Refactoring the existing `SlotFillPopover`** (slot-anchored)
  — keep what works, only rename. A future doc can audit its UX
- **Full natural-language date parser.** Cover the small grammar
  above; defer cron-like or recurring-rule expressions
- **Dragging the task across the Today timeline** as an
  alternative to this picker. That belongs to `today.md`
- **Cross-week candidates** («next Tue»). The mockup shows
  Today + Tomorrow only. Extend horizon only when there's a
  reason
- **Voice input** for the NL field. Tempting on macOS with
  Dictation, but separate
- **Showing the slot ranker's score** numerically. The badge text
  («free 1 h», «before standup») is the user-facing summary;
  exposing the raw score reads as algorithmic exhaust
