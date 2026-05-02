# Bubo — JTBD Self‑Audit

A demand‑side companion to `PRINCIPLES.md`. The principles describe *how*
Bubo is built. This document describes *what for*: the jobs users hire
Bubo to do, and where the current UI fails those jobs. Every diagnosis
cites the principle it leans on (`§N`) and a primary source — Apple
Human Interface Guidelines or Ilya Birman's design tradition.

The audit is opinionated and incomplete on purpose. It is a queue of
work, not a survey.

---

## 1 · How to read this document

`PRINCIPLES.md` is the lint rule. This audit is the bug list. They are
read together: a reviewer walking a UI change uses the principles
checklist (§"Quick reference for reviewers") to judge the patch, and
this audit to judge the surface the patch lives on.

Two conventions:

- *Surface* means a bounded region of the UI a user can name —
  "Backlog header", "World Clock strip", "More ⌄ menu".
- *Job* means a JTBD‑style outcome a user is buying with Bubo, in
  "When ___, I want to ___, so I can ___" form.

A finding is only worth writing if it changes a recommendation. We do
not catalogue what works.

---

## 2 · Jobs To Be Done

Five jobs, ordered by how often they are hired in a working day.

### J1 · Triage after an interruption

> *When I open my laptop after lunch or a meeting, I want to see what's
> overdue and what's next, so I can stop holding it in my head.*

- **Hire trigger**: returning to the desk; the menu‑bar icon is the
  first thing the eye meets.
- **Felt success**: relief — the queue is visible, the next move is
  obvious, the backlog is not accusatory.
- **Failure mode**: the popover demands re‑reading. Multiple "loud"
  elements compete; the user closes it without acting.
- **Surfaces**: `MenuBarView` header, `BacklogHeader`, `SmartActions`,
  `DaySectionView`.

### J2 · Capture mid‑flow

> *When a task lands while I am working, I want to log it in under two
> seconds without leaving the keyboard, so my focus survives.*

- **Hire trigger**: a thought arrives; hands are on the keyboard.
- **Felt success**: it is captured before the thought decays. The
  source app is still focused.
- **Failure mode**: the user has to mouse to the menu bar, click,
  type, click again. The thought is gone.
- **Surfaces**: `QuickCaptureView` (global hotkey), `CommandPalette`,
  the `+ Add` footer button.

### J3 · Plan the day inside working hours

> *When I start the morning, I want to fit the queue into working hours,
> so I commit only to what fits.*

- **Hire trigger**: morning, fresh queue, calendar synced.
- **Felt success**: a credible plan, free slots labelled honestly,
  over‑commit visible.
- **Failure mode**: the timeline lies (free slot looks free but is
  reserved, working hours bleed into the queue silently).
- **Surfaces**: `BacklogFullscreenView`, `DaySectionView`,
  `EndOfDayBanner`, `OptimizerTabView`.

### J4 · Cross‑zone awareness

> *When my collaborators are in three time zones, I want a glance‑
> confirmable clock, so I don't miscount hours.*

- **Hire trigger**: about to send "are you free at 4?" to someone in
  another zone.
- **Felt success**: the answer is read off the strip in under a
  second; the offset sign is unambiguous.
- **Failure mode**: the user opens a separate world‑clock app
  anyway. Bubo has lost the job.
- **Surfaces**: `WorldClockStripView`, `WorldClockTabView`.

### J5 · Recover after a derailed day

> *When the day didn't go to plan, I want to roll the remainder forward
> without ceremony, so I don't relitigate every task.*

- **Hire trigger**: end of working hours, queue not empty.
- **Felt success**: one click, queue is tomorrow's problem, no
  guilt prompt.
- **Failure mode**: per‑task reschedule, modal confirmations, the
  user stops opening Bubo at end of day.
- **Surfaces**: `EndOfDayBanner`, `ToastView` (undo path).

---

## 3 · Surface‑by‑surface walk

For each surface: *job served · current behaviour · frictions ·
recommendations*.

### 3.1 · `MenuBarView` — the popover as a whole

- **Job**: J1 (triage) primary, J2 (capture) via the footer.
- **Current**: world clock strip, colour dot row, expanded backlog
  group with `BacklogHeader` + `SmartActions` + a single task,
  `DaySectionView` for today and tomorrow, footer with `More ⌄` and
  `+ Add`.
- **Frictions**:
  1. The first three rows the eye meets — clocks, dots, backlog
     header — all read as "primary". `§1` says one primary action per
     screen; here three regions compete for attention.
  2. The colour‑dot row has no caption and no documented job. A
     first‑time user cannot tell if it is a filter, a tag picker, or
     decoration. *HIG · Layout*: controls earn their pixels by being
     understood without explanation.
- **Recommendations**:
  - Demote either the clock strip or the colour dots out of the
    chrome. Candidate: hide colour dots behind a hover/tap on the
    `BacklogHeader` count, since they edit a property of the queue,
    not the window.
  - Treat `+ Add` as the only persistently visible primary action
    (`§1`). Everything else in the footer drops to one borderless
    style on the opposite side.

### 3.2 · `WorldClockStripView`

- **Job**: J4. This surface is the entire job.
- **Current**: three pill chips (`UTC 08:05 −3 h`, `Moscow 11:05`,
  `Belgrade 10:05 −1 h`).
- **Frictions**:
  1. The offset uses a hyphen (`-3 h`) where `§3` and HIG agree on
     `−` (U+2212) for numeric negatives.
  2. `−3 h` has a space between number and unit and is breakable;
     wants a non‑breaking space.
  3. There is no obvious affordance to reorder or remove a zone
     inline. Users who hit the wrong city in `WorldClockTabView`
     return to settings to fix it (`§4` mode creep, `§9` direct
     manipulation lost).
- **Recommendations**:
  - Use `−` and a non‑breaking space: `−3\u{00A0}h`.
  - Add a context‑menu on each pill: "Move left", "Move right",
    "Remove". `§9` rank 2 (right‑click the thing) is reachable.

### 3.3 · `ColorDotButton` row

- **Job**: undocumented. Candidates: filter the backlog by colour
  tag, set the colour of the next captured task, or both modes
  toggling silently.
- **Frictions**: ambiguity. Same control, two possible jobs, no
  affordance separating them. `§4` says modes are where UI goes to
  die; an invisible mode is the worst kind.
- **Recommendations**:
  - Decide the job in writing (`§11`: name the principles in
    tension).
  - If filter: collapse into the `SegmentedPillPicker` (3.6).
  - If next‑task colour: move into the `+ Add` flow and the
    capture overlay; remove from the popover chrome.

### 3.4 · `BacklogHeader` — `Components/BacklogHeader.swift:47`

- **Job**: J1.
- **Current**: capacity ring · "19 tasks" · arrow expand · sort
  toggle. Subline: "After hours · 19 h queued". Below: "1 urgent"
  pill in `systemRed`. Below: weekday strip with one day
  highlighted.
- **Frictions**:
  1. "1 urgent" repeats inside `SmartActions` ("Pack urgent tasks
     first / 1 urgent"). Two badges for one fact (`§1`, *Birman:
     dominant element*).
  2. "After hours · 19 h queued" mixes the verdict and the
     measurement in one breath. The verdict ("After hours") and the
     metric ("19 h queued") want different weights.
  3. "19 h" — non‑breaking space between number and unit (`§3`).
  4. The weekday strip duplicates information already on the
     timeline below it.
- **Recommendations**:
  - Drop the weekday strip from the header inside the popover;
    keep it only in `BacklogFullscreenView` where the timeline is
    not co‑resident.
  - One urgent badge total per popover. The header's pill stays;
    the SmartActions card stops repeating it.
  - Rewrite the subline using `DS.formatMinutes` siblings:
    "After hours · 19\u{00A0}h queued".

### 3.5 · `SmartActions` — `Components/SmartActions.swift:23`

- **Job**: J1, J3.
- **Current**: a card titled "Pack urgent tasks first", with
  "19\u{00A0}tasks · 19\u{00A0}h over" and a `Run` action. Visible
  identically in the main popover (group expanded) and in the
  `BacklogFullscreenView`.
- **Frictions**:
  1. Same card in two places that the user can see in one workflow.
     The second showing teaches nothing new (`§1`, *Birman:
     redundancy is a failure of editing*).
  2. The card's recommendation is computable; the user is asked to
     press `Run`. If the action is always safe and reversible, the
     card is begging for `§5` (undo over confirm) — auto‑apply, show
     the undo toast.
- **Recommendations**:
  - Show the card in *one* place per session. Inside the popover,
    expanded backlog group hides the card; the fullscreen view shows
    it. Or vice versa.
  - For "Pack urgent tasks first" specifically: auto‑apply on first
    open of the day; produce a toast with `Undo` (`§5`,
    `ToastView`).

### 3.6 · `SegmentedPillPicker` filter chips

- **Job**: J1.
- **Current**: chips for `All 19`, `Today 1`, `Flagged 1`, `Bubo`,
  `Напоминания`.
- **Frictions**:
  1. Mixed axes. *All / Today / Flagged* are status; *Bubo /
     Напоминания* are source. A single chip group cannot be ANDed
     across both axes; the user discovers this only by trying.
  2. *Напоминания* is Russian. There is no localisation
     infrastructure in the repo (no `Localizable.xcstrings`, no
     `NSLocalizedString` calls). One stray Russian string is worse
     than either pure English or proper i18n.
- **Recommendations**:
  - Split into two chip rows or a chip row + source dropdown. *HIG
    · Pickers*: one row, one decision.
  - Until i18n lands, render the source name from the system
    framework's display name (which honours the user's locale)
    instead of a hardcoded string.

### 3.7 · `BacklogView` and `BacklogFullscreenView`

- **Job**: J1, J3.
- **Current**: list of `BacklogTaskRow`, draggable
  (`BacklogTaskRow.swift:414`) onto `FreeSlotRow`
  (`FreeSlotRow.swift:24`). First‑run hint "← Drag a task here" at
  `FreeSlotRow.swift:137`.
- **Frictions**:
  1. Two operations live on the same drag: reorder within the
     backlog and reschedule onto the timeline. Users cannot tell
     before releasing whether they are reordering or scheduling. `§9`
     direct manipulation is achieved, but the *meaning* of the
     manipulation is overloaded.
  2. The drag‑onboarding hint is permanent until the
     `BuboBacklogHasDragged` flag flips. After the first drag the
     hint disappears forever — fine for a single user, but loses
     accessibility for keyboard‑only users who never drag at all.
- **Recommendations**:
  - Distinct hover targets: hovering over a free slot during drag
    glows that slot; hovering over another backlog row shows a
    reorder caret. The two affordances must look different.
  - Provide a keyboard equivalent of the drag — `⌥↑/↓` to reorder,
    `⌘→` to schedule into the next free slot. *HIG ·
    Accessibility*: every pointer interaction needs a keyboard
    twin.

### 3.8 · `DaySectionView` and `EventRowView`

- **Job**: J3.
- **Current**: "Today · 9–19", "Working hours start · 09:00", "Free
  · 7 h 54 min · 11:05–19:00", "Working hours end · 19:00",
  "Tomorrow".
- **Frictions** (microtypography, `§3`):
  1. "9–19" is correct (en‑dash). Good.
  2. "11:05-19:00" in screenshot uses a hyphen; should be `–`.
  3. "7 h 54 min" wants non‑breaking spaces:
     `7\u{00A0}h\u{00A0}54\u{00A0}min`. Otherwise the line breaks
     between `7` and `h` on narrow widths.
- **Recommendations**:
  - Audit every formatter that emits a numeric range or
    number+unit. `DS.formatMinutes` exists; extend it or pair it
    with `DS.formatRange` so the en‑dash and NBSP rules live in one
    place.
  - Add a unit test: any string emitted by `DS.format*` must not
    contain `-` adjacent to a digit, must not contain a regular
    space between digit and unit. `§3` becomes enforceable, not
    aspirational.

### 3.9 · `EndOfDayBanner`, `StatusBannerView`, permission banners

- **Jobs**: J5 (end‑of‑day), J1 (permission banners block triage).
- **Current**: end‑of‑day banner offers "Carry to tomorrow"
  (`EndOfDayBanner`). Permission banners use `PermissionBannerSpec`
  at `MenuBarView.swift:2757`, paged when more than one is active.
- **Frictions**:
  1. Permission banner copy is terse — "Calendar access not
     granted". *HIG · Permissions* asks for a *reason* string; the
     user sees the consequence, not the cause.
  2. The end‑of‑day banner ships J5 entirely on its own. If it is
     dismissed it does not return until tomorrow's end‑of‑day. A
     user who dismisses by accident loses the path.
- **Recommendations**:
  - Rewrite permission copy as
    “Bubo needs Calendar access to show today’s blocks. Open
    Settings → Privacy → Calendar.” *HIG · Privacy*.
  - Expose "Carry to tomorrow" as an item in the `More ⌄` menu so
    the path survives banner dismissal.

### 3.10 · `ToastView`

- **Job**: cross‑cutting — every reversible action.
- **Current**: 2.5\u{00A0}s dismiss, 6\u{00A0}s when an `Undo` button
  is present. Used by refresh, by destructive task actions.
- **Frictions**:
  1. 6\u{00A0}s is short for a deliberate undo, especially for users on
     screen readers (*HIG · Accessibility*: time‑limited UI must be
     extendable).
  2. Several destructive actions in the codebase still confirm
     instead of toasting. Inventory needed (`§5`).
- **Recommendations**:
  - Pause the dismiss timer while VoiceOver is announcing the toast
    or while the pointer is hovering it.
  - Audit every `Button(role: .destructive)` and every confirmation
    dialog: which can become "do it now, undo via toast" per `§5`.

### 3.11 · `CommandPalette` and `QuickCaptureView`

- **Jobs**: J2.
- **Current**: global hotkey `⌃⇧⌘Space` opens `QuickCaptureView`.
  `CommandPalette` provides intent‑aware suggestions and an
  AI‑composition path.
- **Frictions**:
  1. The hotkey is invisible — nowhere in the UI does Bubo say "you
     can capture without opening this window". *HIG · Discoverability
     of shortcuts*.
  2. Two capture paths (palette and quick capture) without a clear
     story of when to use which (`§4` adjacent: a hidden mode by
     virtue of having two doors).
- **Recommendations**:
  - Show the hotkey next to `+ Add` in the footer
    (e.g. "Add  ⌃⇧⌘Space"). One visible hotkey is worth ten in a
    settings tab.
  - Document the split: `QuickCapture` is one‑line, no fields;
    `CommandPalette` is for actions on existing things. If they ever
    overlap, fold one into the other.

### 3.12 · `TimerScreenView` and Pomodoro flow

- **Job**: a sixth job, latent, not yet promoted to §2: *focus
  protection* — "When I start a work block, I want to defend it from
  myself." See `docs/Pomodoro.md` for the rhythms.
- **Frictions**:
  1. Full‑screen timer competes with the menu‑bar identity. Users
     hire Bubo to *stay in the menu bar*; full‑screen takeover is a
     surprise.
  2. Phase boundaries between focus and break rely on a system
     notification that may be silenced.
- **Recommendations**:
  - Make full‑screen opt‑in per session, not the default; default
    to a menu‑bar bezel + system notification.
  - Treat the timer's identity as a permanent menu‑bar accessory
    (the icon shows the remaining minutes), so the user cannot
    accidentally lose track.

### 3.13 · `SettingsView` and the eight tabs

- **Frictions**:
  1. *Reminders* and *Apple Reminders* are two adjacent tabs. The
     first is Bubo's notification cadence; the second is import from
     Apple Reminders. The names collide. *Birman: a name that needs
     a footnote is the wrong name*.
  2. *Optimizer* and *Assistant* both touch automated planning.
     Users will not consistently predict which tab owns "auto‑pack
     urgent".
  3. Defaults audit needed. Are they HIG‑calibrated for a fresh
     install — that is, does Bubo *just work* with no settings
     touched?
- **Recommendations**:
  - Rename: "Reminders" → "Notifications schedule"; "Apple
    Reminders" → "Reminders import".
  - Either merge Optimizer and Assistant or write a one‑sentence
    purpose statement at the top of each tab.

### 3.14 · Skin system surface

- **Frictions**:
  1. The skin schema (§10) is excellent. The chooser UI is not
     audited here; the question is whether a user finishes choosing.
     The principle: the skin chooser is a configuration surface, not
     a play surface, and should disappear after first use.
- **Recommendations**:
  - Move the skin chooser one level deeper than the General tab if
    not already there, and add "set and forget" affordance (a
    "Use this" button that visually closes the choice).

### 3.15 · The `More ⌄` menu

- **Current** (`MenuBarView.swift:2650–2679`): Refresh Calendars
  (⌘R), Settings (⌘,), divider, Quit Bubo (destructive, ⌘Q).
- **Frictions**: none significant. The menu is small and respects
  `§1`.
- **Recommendations**: keep it small. Resist the urge to use it as
  a parking lot for new actions.

---

## 4 · Cross‑cutting findings

1. **Microtypography drift** (`§3`). Multiple time strings ship
   hyphens, regular spaces between number and unit, and ASCII
   ellipses. The fix is one helper module, not per‑surface edits.
2. **Hierarchy contention** (`§1`). Three or more "primary‑looking"
   elements in the popover. The cure is editing, not adding.
3. **Mode creep** (`§4`). The colour‑dot row, the dual capture
   paths, and the SmartActions duplication all hint at modes that
   exist by accident.
4. **Onboarding and permission copy**. Banners say *what* failed
   and not *why* the user should care; HIG asks for reason strings.
5. **Localisation**. One Russian string ("Напоминания") in an
   otherwise English UI with no i18n infrastructure. Either commit
   to localisation or remove the string.
6. **Accessibility**. Reduce Motion is partially honoured;
   VoiceOver labels are scattered; the Increase Contrast path
   through the skin system is undocumented for contributors.

---

## 5 · Prioritised backlog

| # | Severity | Effort | Job | Item |
|---|----------|--------|-----|------|
| 1 | High | S | J1, J3 | Centralise `–` / NBSP / `−` formatting; replace ad‑hoc strings (`§3`). |
| 2 | High | S | J1 | Show `SmartActions · Pack urgent` in only one place per session (`§1`). |
| 3 | High | S | J1 | Drop the weekday strip from the in‑popover `BacklogHeader` (`§1`). |
| 4 | Med  | S | J1 | Decide and document the colour‑dot row's job; demote or relocate (`§4`, `§11`). |
| 5 | Med  | M | J1 | Split status × source axes in `SegmentedPillPicker` (`§4`). |
| 6 | Med  | M | J3 | Distinguish reorder‑drag from schedule‑drag visually (`§9`). |
| 7 | Med  | M | J5 | Audit destructive confirms; convert to undo toasts (`§5`). |
| 8 | Med  | M | J2 | Surface the global capture hotkey next to `+ Add` (HIG · Discoverability). |
| 9 | Med  | M | — | Rewrite permission‑request copy with reason strings (HIG · Privacy). |
| 10 | Med | L | — | Settings IA pass: rename Reminders / Apple Reminders; consolidate Optimizer/Assistant. |
| 11 | Low | L | — | Localisation infrastructure or removal of Russian string. |
| 12 | Low | L | — | Accessibility sweep: VoiceOver labels, Reduce Motion gaps, Increase Contrast docs. |
| 13 | Low | L | — | First‑run onboarding (replace one‑shot `← Drag a task here` hint with a small story). |
| 14 | Low | M | — | Empty‑state component (no tasks, no calendar access, no reminders). |

*S = under a day · M = a focused PR · L = an architecture decision.*

---

## 6 · Open questions

1. Is the colour‑dot row a filter or a tag creator? Both? Neither?
   (Blocks item 4.)
2. Is Bubo committing to localisation in 2026? If yes, which locales
   first? (Blocks item 11.)
3. Is the timer a first‑class job (§2 J‑extra) or an accessory to
   J3? (Decides whether 3.12 deserves a J‑number of its own.)
4. Should `Run` on `SmartActions` ever be a non‑auto‑apply action,
   or is auto‑apply‑with‑undo the universal answer? (Decides item
   2's exact shape.)

When these are answered, the affected backlog rows lose their
"document the job first" prefix and become normal PR work.
