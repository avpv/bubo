# UX / CJM Audit

Live-build audit (2026-07-05) from four popover screenshots — main
timeline, Backlog (1 task / empty), New Event — checked against
`PRINCIPLES.md`. Complement to `UI_REFACTORING.md`: that doc fixed the
code shape, this one tracks what the *user* meets. Each finding names
the principle it violates, so fixes argue from the app's own rules.

## Fixed (2026-07-05)

| # | Finding | Fix |
|---|---|---|
| 1 | **Hard verb over an empty state.** «Schedule overflow» (warning-tinted, the strongest chip in the app) rendered on an empty backlog and on the main screen with zero tasks — every closed workday window (evening, weekend, off-day) resolved to `.afterHours`, and every consumer reads `.afterHours` as hard. A brand-new user's first screen shouted «fix your overflow» over nothing. | `BacklogLogic.capacityForecast` returns `.fits` when nothing is pending; hard states now require actual queued work. Tests added. |
| 2 | **Red capacity ring for a benign queue.** One 1-hour task on a Sunday drew the ring in saturated destructive red (`capacityFraction` returned the 1.5 over-capacity sentinel whenever the window was closed). §7: red is reserved for broken/overdue; work parked for tomorrow is neither. | Sentinel moved to 1.1 — the ring's warning band. Empty-after-hours returns 0. Test updated + added. |
| 3 | **World-clock strip inside the New Event form.** The main screen's context band mounted at the top of a modal creation form — chrome before the title field, no role in creating an event (§2: one band per role; a form's roles are title → fields → commit). | Strip removed from `AddEventView`; unused `settings` dependency dropped. |

## Open findings

### F4 — The same fact shown 2–3× on the main screen (§3)

One empty Sunday renders: header subtitle «No events today», day-section
summary «9–22 · 0 events», and two working-hours rows repeating 09:00 /
22:00. Three surfaces, one fact (window + emptiness).
**Proposal:** on a day with 0 events, the day-section summary drops the
«0 events» clause (header already says it); working-hours boundary rows
render on today only (they are already informational-only elsewhere).
Low risk, view-local.

### F5 — Three chrome bands before content (§2)

At rest the main screen stacks action chips + world clock + colour
filter before the first event. On an empty day the popover is mostly
chrome. The colour filter is a niche verb permanently occupying a band;
world clock is «always visible (per design intent)» but competes with
the timeline.
**Proposal (needs a product decision):** collapse the colour filter
behind a small filter glyph in the day-nav cluster (band appears only
while filtering, like the free-slot picker state); keep world clock
always-on only if cities are configured (it already self-guards) — or
fold it into the header line. Either halves the resting chrome.

### F6 — Working-hours boundary rows are heavy for a set-once setting

A draggable ±1 h control renders twice per day section, every day. The
control is well made, but working hours change rarely; the CJM cost is
two interactive rows of noise per day between the user and their events.
**Proposal:** interactive on today only (partially true already),
plain hairline + time on other days, or a single «9–22» affordance in
the day header that opens the stepper on click.

### F7 — Machine-precision copy in free slots

«Free · 12 h 33 min · 09:26–22:00» — second-level precision for a
planning glance (§6 wants machine hints quiet, not exact-to-the-minute).
**Proposal:** round starts to 5 min, drop the minutes when ≥ 2 h
(«Free · ~12½ h until 22:00»). Copy-only.

### F8 — CJM: nine entry points for «get something scheduled»

Inventory from the live build: ① footer «Add event», ② «+» on a free
slot, ③ «Focus» on a free slot, ④ backlog add-task field, ⑤ ⇧⌘N quick
capture, ⑥ «Plan» chip / ⌘K palette, ⑦ «Schedule overflow», ⑧ drag task
→ slot, ⑨ «Tasks» footer button → backlog. Three vocabularies (event /
task / plan) with no visible rule for which to use — this is the core
«запутанный CJM» complaint.
**Proposal, staged:**
- **A. Fewer verbs at rest** — partly done via fix #1: hard chips only
  with real overflow; one contextual chip max (already the SmartActions
  contract).
- **B. One front door for creation** — **landed 2026-07-05** (user
  decision). The footer primary is now «Add» (⌘N): a Quick Add popover
  (`QuickAddView`) accepts free text and routes it by one learnable
  rule — an explicit clock time makes it an event, everything else is a
  task (`QuickAddParser`, unit-tested). The interpretation previews live
  under the field before commit (§6); ↩ commits with an undo toast, ⇧↩
  escapes to the matching detailed form pre-filled. «New Event…» /
  «New Task…» stay as menu escapes on the same button. The ⇧⌘N global
  quick capture is unchanged (task-only) — upgrading it to the same
  parser is the natural follow-up.
  **Amended 2026-07-16 (user feedback):** one window for both types was
  inconvenient in practice — Quick Add gained a segmented Auto / Task /
  Event switcher (⌘1/⌘2/⌘3, remembered across opens). Task / Event pin
  the interpretation so the field acts as a dedicated composer; forced
  Event with no typed time defaults to the next quarter-hour, previewed
  with the §6 guess tilde. Auto keeps the original rule.
  **Amended again 2026-07-16 (user feedback):** the detailed New Event
  form was the preferred way to create events — the footer primary
  «Add» (⌘N) opens it directly again. Quick Add is demoted to a menu
  escape («Quick Add…») and its own shortcut ⇧⌘N; «New Task…» stays in
  the menu. The one-front-door rule is thereby relaxed: the front door
  is the event form, with capture surfaces one step away.
- **C. Palette as the only planner home** (already the code's stated
  intent): «Plan N», «Schedule overflow», «Focus» become palette
  presets surfaced contextually, not permanent chrome. Not started —
  needs its own pass.

**Declined for now (user decision, 2026-07-05):** F5's chrome collapse
— the world clock and colour-filter bands stay always-visible.

### F9 — New Event form ergonomics — **RESOLVED 2026-07-15**

Duration requires computing an end time (Starts 09:30 / Ends 10:00);
no duration pills (30 m / 1 h / 2 h) although the backlog side already
thinks in durations. «Add to Calendar» is an unchecked-by-default box
whose caption describes the negative («stored locally…») — correct but
reads as a warning.
**Proposal:** duration pills next to the Ends row driving `Ends`;
caption flips to positive when checked («Will sync to Apple Calendar»).
**Landed:** duration chip row (15 m – 2 h, same `ChipButton` voice as
NewTaskView's Duration row) under the Ends pickers driving `duration`;
the calendar caption now speaks in both states — «Will sync to Apple
Calendar» when checked, the local-storage fact when not.

### F10 — Two machines disagree about whether today is workable — **RESOLVED 2026-07-05**

Seen live on the 2026-07-05 build screenshots: a Sunday showed «Free ·
~10½ h» on the timeline while the verdict said «After hours · 2 h
queued» — `capacityForecast` respected `workingDays` (Sunday off ⇒
window closed) while the free-slot machinery only honoured
`workingHours`.
**Decision (product owner): the verdict reads the clock only.** The
capacity surfaces (Plan chip label, backlog verdict, ring/partition
via `remainingWorkdayMinutes`) no longer pass `workingDays` — an
off-day with time on the clock says «Done by …» and agrees with the
timeline's slots. `workingDays` remains an **auto-placement** rule:
the GA and the naive proposed-slot projection still refuse to place
work on off-days, and «Copy availability» still skips them. The domain
function keeps its `workingDays` parameter (default `[]`) for those
callers; only the verdict call sites dropped it.

## Acceptance

No Swift toolchain in this environment — every stage lands as a PR to
be built + screenshot-verified on macOS, same protocol as
`UI_REFACTORING.md` stages.
