# Interface refactor — Roadmap

This roadmap drives the in-place visual + view-structure rewrite of the
Bubo menu-bar UI against the third-pass HTML prototype
(`a0fcc702-index3.html`). The authoritative design contract is
`docs/refactor/prototype-spec.md`.

The work is split into **waves**. Wave 0 (foundation) is committed on
this branch; Waves 1–N consume that foundation, one screen each, and
should be done in environments with a working Swift toolchain so each
commit can be `swift build`-validated before pushing.

## Wave 0 — Foundation (this commit)

Additive only — no existing files in `Bubo/Presentation/Views` were
behaviourally changed beyond two new `DS` token slots. Done so the rest
of the refactor lands on a shared rhythm.

- `Bubo/Presentation/Views/DesignSystem/DesignSystem+Sizes.swift` —
  added prototype-aligned semantic radii (`radiusSm/Md/Lg/Pill`),
  `cityChipHeight`, `colorFilterHeight`, `iconButton`, `eventStripeWidth`.
- `Bubo/Presentation/Views/DesignSystem/DesignSystem+Prototype.swift` —
  new file. `DS.Fg.*` (four-step opacity ramp), `DS.Mix.*` (canonical
  accent / surface tint percentages), `DS.PopoverShadow.*` (popover /
  palette / alert depth tiers), `DS.Motion.micro` (120 ms ease).
- `Bubo/Presentation/Views/Components/Common/PopoverShell.swift` — the
  shared popover container (material + halo + corner + border + shadow)
  every popover should compose as its root. Cross-cutting guidance #2.
- `Bubo/Presentation/Views/Components/Common/KbdChip.swift` — single
  source for keyboard hint pills (`KbdChip`, `KbdHint`). Cross-cutting
  guidance #4.
- `Bubo/Presentation/Views/Components/Common/IconButton.swift` — the
  prototype `.icon-btn` (28 × 28, accent-hover lift).
- `Bubo/Presentation/Views/Components/Common/WorkingHoursLine.swift` —
  the sunrise / sunset bookend (`.wh-line`).
- `docs/refactor/prototype-spec.md` — the design contract (~9 k words).

## Wave 1 — Today popover

Files (visual + structural rewrite per `prototype-spec.md` §1):

- `Bubo/Presentation/Views/MenuBar/MenuBarView+MainContent.swift`
- `Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift`
- `Bubo/Presentation/Views/MenuBar/MenuBarView+DayGroup.swift`
- `Bubo/Presentation/Views/MenuBar/MenuBarView+Timeline.swift`
- `Bubo/Presentation/Views/MenuBar/NowNextLine.swift`
- `Bubo/Presentation/Views/Components/Slot/FreeSlotRow.swift`
- `Bubo/Presentation/Views/Components/Common/WorldClockStripView.swift`
  — restyle `WorldClockPill` as `.city-chip` (26 px pill, no platter
  depth, accent-tinted border for the home city only).
- `Bubo/Presentation/Views/Components/Picker/ColorFilterBar.swift` —
  recompose into the prototype's inline `.color-filter` pill
  (icon + label + active dots + count + separator + slots toggle).

Key visual rules:
- Event row: 78 px time column, 3 px stripe in `--cal-color`, body gap 3.
- Working-hours bookend uses the new `WorkingHoursLine`.
- Day-headers are sticky with `--surface-window` 92 % + blur 20 px.
- States (`past` → opacity 0.5, `now` → orange "Now" badge with accent
  stripe, `cancelled` → diagonal stripe + line-through, `declined` →
  row 0.55 opacity, `travel` → vertical-dash stripe, `reminder` →
  dotted stripe). Encode as four `Shape` variants of the stripe.

## Wave 2 — Backlog (3 states)

Files (`prototype-spec.md` §§2–4):

- `Bubo/Presentation/Views/Backlog/BacklogFullscreenView.swift` —
  monolith (954 LOC). Carve into `Header` / `ScopeRow` / `TipRow` /
  `Tasks` / `TomorrowPeek` / `Composer` / `SelBar` views.
- `Bubo/Presentation/Views/Backlog/BacklogFullscreenView+BulkActions.swift`
- `Bubo/Presentation/Views/Components/Backlog/*` — shrink and align
  with the prototype's chip-row + task-row idioms.

Hard product rule: **checkbox = complete only**. Selection tints the
row to `accent 8 %`; it does **not** check the box.

## Wave 3 — Task details + Add / Edit task

Files (`prototype-spec.md` §5):

- `Bubo/Presentation/Views/Event/EventDetailView.swift`
- `Bubo/Presentation/Views/Event/AddEventView.swift`
- `Bubo/Presentation/Views/Event/EditTaskView.swift`
- `Bubo/Presentation/Views/Event/NewTaskView.swift`

Adopt the `.task-pop` structure: hero title block, chip meta-row,
subtasks with progress, tags, source row, activity row, action bar.

## Wave 4 — Slot picker

File: `Bubo/Presentation/Views/Components/Slot/SlotPickerPopover.swift`
per `prototype-spec.md` §6.

## Wave 5 — Pomodoro mini-window

File: `Bubo/Presentation/Views/Timer/TimerScreenView.swift` per §7.
The 140 px ring, orange→pink primary, controls cluster — visual rewrite
only; the existing state machine stays.

## Wave 6 — Command palette

Files (`prototype-spec.md` §8):

- `Bubo/Presentation/Views/CommandPalette/CommandPalette.swift`
- `Bubo/Presentation/Views/CommandPalette/CommandPalette+Actions.swift`
- `Bubo/Presentation/Views/CommandPalette/CommandPalette+Status.swift`

Use the new `PopoverShell(depth: .palette)` for the heavier drop shadow.

## Wave 7 — Settings (general / AI / Appearance)

Files (`prototype-spec.md` §9):

- `Bubo/Presentation/Views/Settings/SettingsView.swift`
- `Bubo/Presentation/Views/Settings/AITabView.swift`
- `Bubo/Presentation/Views/Settings/AppearanceTabView.swift`
- `Bubo/Presentation/Views/Settings/GeneralTabView.swift`
- plus the per-feature tabs (Reminders, Calendars, Optimizer, Assistant,
  Apple Reminders, World Clock).

Pin tabs to the prototype's `.settings-tabs` shape; rows to
`.settings-row` with the new `KbdChip` for shortcut hints.

## Wave 8 — Full-screen meeting alert (J4)

File: `Bubo/Presentation/Views/FullScreenAlert/FullScreenAlertView.swift`
per `prototype-spec.md` §10. Use `PopoverShell(depth: .alert,
showsSkinHalo: false)` and `radius: DS.Size.radiusLg`. (J1 join ribbon
is intentionally **out of scope** — user request.)

## Operating rules for each wave

1. Open `docs/refactor/prototype-spec.md` and read the relevant §.
2. Open the listed Swift files; refactor in place, do **not** start a
   parallel `MenuBarView2`-style file.
3. Use Wave 0 atoms (`PopoverShell`, `KbdChip`, `IconButton`,
   `WorkingHoursLine`) wherever they fit instead of reinventing.
4. Use `DS.Mix.*` / `DS.Fg.*` / `DS.Size.radius*` for any new tint
   expressions — keep magic numbers out of view files.
5. Run `swift build` after each wave; do not ship until it's green.
6. Commit per wave with a `refactor(<screen>): …` message.

The spec is the source of truth for any disagreement between «what the
prototype shows» and «what the current Swift does».
