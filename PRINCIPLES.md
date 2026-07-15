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

Two corollaries. A fact that never varies is not information: per-item
metadata (a calendar caption, an owner name) renders only when it
discriminates between the items on screen — repeated identically down
every row it is noise wearing a label. And today's date has one home,
the screen header; section headers say «Today», not the date again.

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
(`fixedSize`); titles wrap and truncate instead. «Seoul 17…» is half
a clock — worse than no clock.

A strip that can overflow scrolls horizontally with per-element
alignment snapping, and signals the overflow with edge fades that
appear only on the side that actually hides more content. A fade over
a terminal element — dimming the last clock when nothing follows —
is a lie about overflow and violates this section in spirit.

## §11 — Chrome is banded, content is not boxed

Every popover screen has the same anatomy: an identity bar (title,
verdict, quiet machine lines) on a skin bar closed by one hairline
(`SkinSeparator`), then the unboxed workspace, then the footer bar.
The hairline under the header is the screen's single structural line;
inside the workspace only sticky section headers may carry a bar of
their own. Rows, strips, and rails never get frames — if a zone needs
separating, first reach for §2 (rhythm), and only band it when it is
genuinely chrome: fixed, non-scrolling, screen-level.

The action rail (the screen's primary verb) belongs to the workspace
side of the hairline, not the identity bar — it acts on the content,
so it lives with the content.

## §12 — Edges breathe

The first band owns its breathing room from the window's top edge and
the last band from the bottom; nothing renders flush against a window
edge or tight under a hairline. Edge margins are the band's own chrome
(§2) — top padding on the header, not a spacer in the screen layout —
so a screen that swaps its first band keeps its breathing room.
