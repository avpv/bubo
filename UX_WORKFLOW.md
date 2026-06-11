# UX Workflow

The interaction model Bubo is built around, decided 2026-06-11 after
the UI refactor (`UI_REFACTORING.md`) made the screens composable. The
previous model — tasks on one screen, calendar on another, planning
through command chips — made the basic daily loop require navigation;
this document defines the replacement.

## Two surfaces, two jobs

### 1. Menu-bar popover — «glance & join»

The popover answers, in under a second: *what is happening now, what is
next, how long until it, join it, capture a thought.* It is NOT the
planning surface.

Keeps: header (day + next-in), now/next timeline, join affordances,
quick capture (⇧⌘N), world clock, colour filters, full-screen alert
pipeline. Sheds (eventually): planning chips beyond a single «Plan…»
that opens the planner window.

### 2. Planner window — «one screen Today»

A real macOS window (⌘P / footer entry / «Plan» chip) where the entire
planning loop happens **on one screen with direct manipulation**:

```
┌────────────────────────┬──────────────────────────────────┐
│ TASKS (backlog)        │ TODAY (timeline)                 │
│                        │                                  │
│ ○ выпилить крипту 1h   │ 09:00 ── working hours ──        │
│ ○ ембед рабочий  1h    │ ░ Free · 2h        [drop here]   │
│ ○ robot-vertis…  1h    │ ▌11:00 Хурал                     │
│                        │ ░ Free · 45m       [drop here]   │
│ + Add task…            │ ▌14:00 Сережа:Андрей             │
└────────────────────────┴──────────────────────────────────┘
```

Core loop (zero navigation):
- **See** tasks and free slots side by side.
- **Drag** a task onto a slot → scheduled (existing
  `BacklogTaskDrag` → slot-drop pipeline).
- **Click** the task's schedule affordance → lands in the first slot
  that fits (no aiming required).
- **Capture** in the left column without leaving the screen.
- **Rebuild**: the GA presets (Organize today / Plan week / ⌘K) act on
  the same screen; the result is visible immediately on the right.

## The four jobs, mapped

| Job | Surface | Gesture |
|---|---|---|
| Расставить задачи по дню | Planner | drag-to-slot / click-to-fit |
| Следить за днём и встречами | Popover | open → glance → Join |
| Пересобирать план целиком | Planner | GA presets, result in place |
| Захват задач | Both | ⇧⌘N anywhere; add-field in planner |

## Migration stages

1. **Planner window MVP** (this PR): window scene, two columns reusing
   `BacklogScreenModel` + `MenuBarScreenModel` + the refactored rows;
   drag-to-slot and click-to-first-fit; capture field; entry points
   (footer menu, ⌘P).
2. **Popover slimming**: planning chips collapse to one «Plan» that
   opens the window; backlog fullscreen screen retires once the window
   covers curation (needs usage feedback).
3. **Proactive draft** (optional, after 1–2 prove out): GA pre-computes
   a day draft shown in the planner as ghost blocks with one
   Apply/Adjust gesture — the `shadowProposal` machinery already
   exists.

Each stage gates on a build + a real day of use, not just screenshots:
this is a workflow, the test is working in it.
