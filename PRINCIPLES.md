# PRINCIPLES

The design rules every Bubo surface follows. Code comments cite these
sections (`PRINCIPLES.md §N`); this file is the canonical text.

## §1 — One verb per surface

Each surface exposes exactly one primary action, visually dominant.
Secondary verbs share one quiet voice on the trailing edge. A second
competing call-to-action is a bug, not emphasis. Hard and soft states
own the leading slot alone; suggestions never sit next to a synonym.

## §2 — Rhythm via whitespace, not chrome

Hierarchy comes from spacing and typography, not boxes-in-boxes. One
band per role (action rail, status, context strip); a band that is
empty renders nothing rather than an empty frame. Inter-band rhythm is
owned by the screen layout, never by the bands themselves.

## §3 — Don't show the same fact twice

Every number and verdict has one home. If a count lives in the header,
it does not also live in a pill, a banner, and a summary row. A
suggestion's diagnosis lives in the tooltip when its verb is visible.

## §4 — Don't add modes

Prefer enriching an existing surface over adding a switch, a tab, or a
parallel screen. The command palette is the single home for planner
presets; the settings window is the single home for configuration.

## §5 — Status is not an action

Non-interactive facts never dress like buttons. Anything shaped like a
chip or pill must respond to a click; anything informational reads as
quiet text or a glyph with a tooltip. Banners that can be fixed by the
user are buttons and deep-link to the fix.

## §6 — The machine speaks in one voice

Computed hints — ghost slots («→ 15:30»), duration guesses, ⌘K cues —
use `DS.Typography.machineHint` (monospaced footnote, tertiary). The
user learns to recognise «the computer thinking out loud» and never
confuses it with their own content.

## §7 — Accent is reserved

Accent colour marks the primary CTA, selection, and «now». Suggested
actions are emphasised by fill weight, not colour. Red is split:
saturated destructive for «broken / overdue», desaturated urgent for
«due soon» — the two never compete on one element.

## §8 — Type comes from the ramp

Text uses macOS text styles via `DS.Typography` (and
`sectionHeaderStyle()` / `SectionLabel` for section rubrics — mixed
case, no tracked uppercase). Hand-tuned point sizes are allowed only
for non-text glyphs (dots, rings) and hero numerals.

## §9 — Facts are parameters, verbs are environment

Rows receive data (task, flags, computed hints) as parameters and
actions through environment-injected structs (`BacklogRowActions`).
Threading closures through intermediate layers is the failure mode
that made the interface unmanageable; see `UI_REFACTORING.md`.

## §10 — Every band must fit

No surface may clip mid-element at the popover edge or rely on the
user discovering hidden overflow. Small numeric facts never truncate
(`fixedSize`); titles wrap and truncate instead. Strips that can
overflow page with alignment snapping.
