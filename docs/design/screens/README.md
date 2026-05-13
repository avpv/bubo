# Screen design docs

One file per surface. Each file is **normative** for what the screen
should become — pair-reviewed before the implementation PR, then linked
from that PR.

These docs are a layer above `../PRINCIPLES.md`: PRINCIPLES sets the
grammar (typography, motion, density, modality); screen docs apply
that grammar to a specific JTBD on a specific surface.

## Template

Every screen doc follows the same five-section shape. If a section is
empty for a given screen, keep the heading and write «none» — the
absence is itself information.

```
# <Screen name>

> One-sentence purpose. Who is this for, in what moment.

## 1. JTBD

| # | Когда | Хочу | Чтобы |
|---|-------|------|-------|
| J1 | …     | …    | …     |

## 2. Current state

- **Files** with line ranges
- **Anatomy** as it stands today
- **Known failures**, each tied to a JTBD ID from §1

## 3. Target design

- **Mockup**: `ui_kits/index2.html:N–M` (or its rendered preview)
- **Anatomy** of the target — sections top-down
- **Diff** from current state, as a table

## 4. Acceptance criteria

Punch list for the first refactor PR. Each item is one observable
change a reviewer can verify on a running build.

## 5. Out of scope

What is explicitly deferred to a later PR, and why.
```

## Tier 0 — core daily loop

These five surfaces are the product. The user touches them every day.

- [`backlog.md`](backlog.md) — the job-list / inbox of unscheduled tasks
- [`today.md`](today.md) — the popover with today's timeline + smart actions
- [`task-details.md`](task-details.md) — push from any task row
- [`scenario-picker.md`](scenario-picker.md) — review GA output, pick a plan
- [`slot-picker.md`](slot-picker.md) — pick a time for one task

## Tier 1 — powerful but less frequent

- [`meeting-alert.md`](meeting-alert.md) — fullscreen pre-meeting alert
- [`quick-capture.md`](quick-capture.md) — global hotkey ⌃⇧⌘Space
- [`intent-composer.md`](intent-composer.md) — declarative scheduling rules
- [`pomodoro.md`](pomodoro.md) — focus session mini-window
- [`command-palette.md`](command-palette.md) — ⌘K

## Tier 2 — utility

- [`join-ribbon.md`](join-ribbon.md) — post-join floating bar
- [`menubar-density.md`](menubar-density.md) — menu-bar owl + density bar
- `event-editor.md` — new event / task full editor *(draft)*
- `settings.md` — tabs (Calendars, Reminders, AI, Appearance, General) *(draft)*

## How to write a new screen doc

1. Read `../PRINCIPLES.md` once before you start. The doc should not
   restate them — it should apply them.
2. Fill §1 (JTBD) **before** you look at the mockup. JTBD anchors the
   critique; if the mockup is wrong, JTBD is the test that catches it.
3. Fill §2 by reading the current Swift code with exact line refs.
   «What it does» is one paragraph; «known failures» are bullets.
4. Fill §3 by reading the mockup in `index2.html`. Quote the line range.
   Don't paraphrase what the mockup does — list its sections.
5. Fill §4 as observable acceptance criteria. Each item is a
   pull-request-sized change a human can verify by running the app.
6. Fill §5 honestly. If a great idea doesn't fit this PR, write it
   here, not in §4.

If a JTBD in §1 has no answer in §3 — that's a design hole; either
extend the target or document the deferral in §5. Never silently drop
a JTBD.
