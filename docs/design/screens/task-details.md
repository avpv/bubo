# Task details

> The push view that opens when the user taps a task row. The place
> to read context, walk subtasks, schedule, snooze, or complete — all
> from one surface, with the task's calendar colour as the visual key.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| D1 | Открыл задачу из backlog | Прочитать суть и контекст | Понять, что делать |
| D2 | Веду длинную задачу | Отметить подзадачи по ходу | Видеть прогресс |
| D3 | Задача неактуальна сейчас | Отложить на потом | Не делать решение «удалять или нет» |
| D4 | Готов сделать | Запланировать на конкретное время | Не держать в голове «когда» |
| D5 | Закончил | Отметить выполненной | Получить точку |
| D6 | Задача пришла откуда-то | Открыть источник (Notion, Reminders) | Свериться с оригиналом |

## 2. Current state

### Files

- **Edit view** — `Bubo/Presentation/Views/Event/EditTaskView.swift:1–815`
- **Composition entry** — pushed by `BacklogFullscreenView` and inline
  `BacklogView` via `onEditTask` callback

### Anatomy today

`EditTaskView` is a single tall form (815 lines):

1. `PopoverHeader` — «Edit Task» (`:134–138`)
2. Title `TextField` (`:146–160`)
3. Effort block — duration chips + story-points (`:164–198`)
4. Schedule block — priority / deadline / preferred period (`:202–251`)
5. Colour tag picker (`:256–275`)
6. Project/context field (`:278–291`)
7. «More options» collapsible header (`:294–312`)
8. Details when expanded — location · link · notes (`:319–381`)
9. Subtasks (`:387–391`)
10. Tags (`:398–402`)
11. Recurrence toggle + label (`:407–444`)
12. Dependencies picker (`:447–451`)
13. Cancel / Save footer (`:462–479`)

### Known failures

- **F1 (D1).** «Edit Task» framing implies modal editing. The user
  more often wants to **read and act**, not edit fields. Title is
  buried mid-form rather than acting as the hero.
- **F2 (D2).** Subtasks live in a collapsible section («More options»)
  by default. The single most actionable affordance for an in-flight
  task is hidden behind a toggle.
- **F3 (D3).** No `Snooze` affordance. Defer-by-one-day exists only
  in `BacklogBulkActionsToolbar`, requiring multi-select.
- **F4 (D4).** Schedule is buried inside form fields (priority +
  deadline + period). The actual «put it on the calendar» action
  is not on this view — the user must back out, select, schedule.
- **F5 (D5).** Mark-complete is also not here. The user toggles
  completion via the row checkbox in Backlog only.
- **F6 (D6).** No «Source» affordance. If a task came from Apple
  Reminders or a deep-link URL was added, there's no consistent
  surface for «open the origin».
- **F7 (general).** Form layout treats all fields as equal weight.
  No visual hierarchy connecting the calendar colour of the task to
  the screen that represents it — every task feels identical.

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2150–2275`

### Anatomy (target)

```
┌───────────────────────────────────────────┐
│ ← Backlog                       ☆   ⋯     │ topbar
├═══════════════════════════════════════════┤   ← colour band keyed
│                                           │     to task colour
│  Group snippets — fix screen overflow     │ hero title (no truncate)
│  on dense layouts                         │
│  📆 Schedule  ◷ 1 h  🔋 Medium  🚩 P2     │ meta-chip row
├───────────────────────────────────────────┤
│ Notes                                     │
│ Two-line snippet rows wrap awkwardly…     │
├───────────────────────────────────────────┤
│ Subtasks                          2 of 4  │
│ ☑ Repro the overflow              10 m    │
│ ☑ Find the offending flex rule    15 m    │
│ ☐ Patch + verify on 3 densities   25 m    │
│ ☐ Open a PR, ping the team        10 m    │
│ ▰▰▰▱  50 %                                │
│ + Add subtask                             │
├───────────────────────────────────────────┤
│ Tags                                      │
│ ● menubar   ● bug   ● ship-before-demo  + │
├───────────────────────────────────────────┤
│ Source                                    │
│ 📥 Notion · Skin renderer                ↗│
│    Sprint 21 / Polish / Open issues       │
├───────────────────────────────────────────┤
│ Activity                                  │
│ ✨ Added 2 d ago by Bubo · edited 14:02   │
├───────────────────────────────────────────┤
│ [📆 Schedule]    🌙 Snooze         ✓      │ bottom action bar
└───────────────────────────────────────────┘
```

### Diff vs current

| | Current (`EditTaskView`) | Target (`TaskDetailsView`) |
|---|------|------|
| Frame | «Edit Task» modal-ish | «Backlog ← »-rooted push with colour band |
| Title | one of many fields | hero, two lines, no truncate |
| Effort & priority | sliders/chips in form | compact `tp-chip` row under title |
| Subtasks | inside «More options» | first-class section with progress bar |
| Tags | freeform field | chips with colour dots; `+ Add` chip |
| Source | absent | section with deep-link arrow |
| Schedule | implicit via fields | explicit primary button in bottom bar |
| Snooze | absent | secondary button in bottom bar |
| Mark complete | absent on this view | icon-only button in bottom bar |
| Save/Cancel | footer buttons | auto-save on field exit; no Cancel |
| Colour | colour-tag picker | task's colour drives the top band |

### Open question — row tap gesture

The mockup is rendered as a single HTML page, so its JS treats
**tap on row body** as *select* (toggles `data-selected`, opens
`sel-bar` at the bottom — mockup JS `:3205–3230`). In a real app
with navigation, tap could just as easily mean *open these details*.

Three options:

- **A. Tap = select; double-tap = open details.**
  Matches the mockup JS literally. Familiar from Finder, but
  unusual inside popovers; double-tap is hard to discover.
- **B. Tap = open details; ⌘-click / long-press = select.** *(recommended)*
  Matches Linear, Things 3, Apple Reminders. Push-to-details is
  the most-frequent verb on a task row; selection is a power-user
  flow that earns its modifier. The `checkbox` already handles
  the single-tap completion gesture, and the per-row hover
  affordances (`Plan ›`, `↑↓×`) handle reordering — so the row
  body has no conflict with «open details» as the default tap.
- **C. Tap = select; trailing `›` chevron on hover = open details.**
  Compromise. Adds a sixth hover-revealed element to the row
  (`PRINCIPLES.md §2` density rule pushes back).

Recommendation: **B**. Need a call on this before AC for «push
`TaskDetailsView`» from `backlog.md` can be marked done.

## 4. Acceptance criteria

### New SwiftUI view: `TaskDetailsView`

- [ ] Lives at `Bubo/Presentation/Views/Backlog/TaskDetailsView.swift`
- [ ] Pushed via the existing `onEditTask` callback (rename to
      `onOpenTask` for clarity)
- [ ] Reads the task from `BacklogService` by ID and observes
      changes so concurrent edits (Reminders sync) reflect live

### Topbar

- [ ] `← Backlog` back button on the left
- [ ] `☆` star toggles a starred state (new boolean on `BacklogTask`
      OR mapped onto `priority == .high` — decide in implementation)
- [ ] `⋯` opens a menu: `Duplicate · Delete · Export · …`

### Hero band

- [ ] Background tint = task's `colorTag`, faded to `~10%` opacity.
      Implements §7 of `PRINCIPLES.md` (colour as meaning, here:
      «which calendar lane this lives in»)
- [ ] Title in `.title2`, no truncation, up to 3 lines
- [ ] Meta chip row: `📆 Schedule` (action chip) or `📅 Tue 14:00`
      (state chip) · `◷ <duration>` · `🔋 <energy>` (only if set) ·
      `🚩 <priority>` · subtasks progress «2 of 4» (only if any)

### Notes section

- [ ] Markdown rendering for `task.notes`. Inline-editable on tap
      (becomes a `TextEditor`, blurs on done)

### Subtasks section

- [ ] First-class, always visible if `task.subtasks.isNotEmpty`
- [ ] Per-row: checkbox · label · per-row duration (faint mono)
- [ ] Progress bar under the list, computed from
      `subtasks.filter(\.isDone).count / subtasks.count`
- [ ] `+ Add subtask` row at the bottom — focus jumps to a new
      `TextField` on tap

### Tags section

- [ ] Chip row with per-tag colour dot; tap a chip to remove
- [ ] `+ Add` chip opens an inline editor with autocomplete from
      existing tags across the corpus

### Source section

- [ ] Visible iff `task.url != nil` OR `task.reminderCalendarItemId != nil`
- [ ] Renders the origin icon, list/project name, and a deep-link
      arrow that opens the original (`NSWorkspace.shared.open(url)`)

### Activity section

- [ ] Read-only single line: «Added <ago> by <author>», edited
      timestamp. Pulled from `task.modifiedAt` and (where available)
      sync metadata

### Bottom action bar (`tp-actions`)

- [ ] `[Schedule]` primary — opens `SlotPickerPopover` for this
      task (see `slot-picker.md`). Filled accent button
- [ ] `🌙 Snooze` secondary — menu: `+1 day · +1 week · Until date…`.
      Each option lands in an undo toast (`PRINCIPLES.md §5`)
- [ ] `✓` icon-only — marks complete, undo toast, pops back to
      Backlog

### Save/Cancel removal

- [ ] Remove the `Cancel / Save` footer. All edits auto-save on
      field commit. Title `onCommit` writes; tag chip removal
      writes; subtask checkbox writes. Undo via toast where the
      change is destructive

## 5. Out of scope

- **Star / starred state**. If we adopt it, it's a new
  `BacklogTask.isStarred` field. Until that's a separate doc
  decision, the `☆` button in the topbar can ship as a no-op stub
  (greyed, tooltip «Coming soon»). Better: omit until decided.
- **Energy meta chip.** «Medium energy» is in the mockup but not in
  `BacklogTask` today. Two paths: (a) add `energy: EnergyTag?` to
  the model, (b) drop the chip from the first PR. I recommend (b)
  and add `energy` in a follow-up once we want it for the optimizer
- **Markdown editor for notes.** First PR: plain-text `TextEditor`.
  Markdown render-on-blur, edit-on-tap is a stretch goal
- **Auto-detect URL in notes.** Mockup shows a deep-link as a
  separate section. URL detection inside notes is its own polish
- **Migrating callers of `EditTaskView`.** First PR introduces
  `TaskDetailsView` alongside `EditTaskView`; second PR migrates
  inline backlog and any other callers; third PR removes
  `EditTaskView`. Don't do all three in one
