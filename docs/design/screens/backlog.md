# Backlog

> The job-list. Where unscheduled tasks live until the optimizer or the
> user finds them a slot. Opened when the user wants to plan, capture,
> or triage — not when they want to do.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| J1 | Появилась мысль | Сбросить её в систему за <5 с | Голова была пустой |
| J2 | Планирую день утром | Увидеть, всё ли влезет | Понять, где боль |
| J3 | Дедлайны жмут | Отделить важное от подождёт | Принять решение |
| J4 | Закончил задачу | Отметить и идти к следующей | Не терять поток |
| J5 | Не знаю, за что схватиться | Отдать решение оптимизатору | Довериться плану |
| J6 | План не подошёл | Поправить точечно | Не переделывать всё |

## 2. Current state

### Files

- **Fullscreen view** — `Bubo/Presentation/Views/Backlog/BacklogFullscreenView.swift` (952 lines)
  - `+Actions.swift` · `+BulkActions.swift` · `+Reorder.swift` extensions
- **Inline card** — embedded in `Bubo/Presentation/Views/MenuBar/MenuBarView.swift`
- **Domain model** — `Sources/Domain/Backlog/BacklogTask.swift:8–131`
- **Service** — `Bubo/Application/Backlog/BacklogService.swift`
- **Header component** — `Bubo/Presentation/Views/Components/Backlog/BacklogHeader.swift`
- **Smart-actions row** — `Bubo/Presentation/Views/Components/Backlog/SmartActionsBar.swift` → `SmartActions.swift`

### Anatomy today

Top-down, the fullscreen Backlog has **seven potential mega-rows** above
the task list:

1. `PopoverHeader` (← Today / Backlog title)
2. `blockHeader` — capacity ring + ETA chip + Plan N pill (`BacklogFullscreenView.swift:354`)
3. `suggestionBanner` — «Bubo found a 1 h slot…» (`BacklogFullscreenView.swift:365`)
4. `BacklogSmartActionsRow` — diagnosis + action (`BacklogFullscreenView.swift:373`)
5. `BacklogActiveFilterSummaryRow` — visible only when filters are collapsed
6. `BacklogSmartFilterRow` — Today/Scheduled/Flagged chips
7. `BacklogFilterChipsRow` — project + colour chips

Followed by the list, then `BacklogAddTaskField` or `BacklogBulkActionsToolbar`
at the bottom.

### Known failures

- **F1 (J5).** Four entries into the optimizer (`Schedule`, `Plan N`,
  `Pack urgent first`, `Find a slot`) compete for visual weight. None
  is the obvious «just do it» button. Violates `PRINCIPLES.md §1`.
- **F2 (J3).** Four orthogonal filter axes (urgent · smart · project ·
  colour) compose by AND with no UI hint of the composition. Users
  filter themselves into empty lists; the `filtersCollapsed` flag
  (`BacklogFullscreenView.swift:140`) is a workaround.
- **F3 (J2).** Capacity ring, ETA chip, and «Plan N» pill say one
  thing three ways: «will it fit».
- **F4 (J1).** `+ Add task…` lives at the bottom of seven rows. Capture
  is the most-frequent job and gets the worst real estate.
- **F5 (J6).** Drag-onto-timeline-slot is unavailable from this view —
  `PRINCIPLES.md §9` would put direct manipulation first.
- **F6 (J5).** `Plan` and `Schedule` mean different things in
  different surfaces — `Plan` in tip-row runs the optimizer, `Plan ›`
  per row opens the slot picker, `Schedule` in `sel-bar` runs bulk
  GA. Three verbs for adjacent jobs.

## 3. Target design

- **Mockup**: `ui_kits/index2.html:1838–2148` (Add / Selected / Empty)

### Anatomy (target)

```
┌───────────────────────────────────────────┐
│ ← Today      Backlog              ⋯       │ topbar
├───────────────────────────────────────────┤
│ 2 tasks → 20:25            All Tasks ▾    │ scope (no ring)
│ Done by 20:25 · all fits inside today     │ verdict text
├───────────────────────────────────────────┤
│ ✨ 1 task ready · Group snippets  [Plan]  │ tip-row (always occupied)
├───────────────────────────────────────────┤
│ ⇅  [All 2] [Scheduled 1] [Completed 0]    │ segmented (3 chips)
├───────────────────────────────────────────┤
│ ○  Group snippets — fix screen      1h    │ row idle (unsched)
│ │ ○  Ad traffic clean-up      📅 Tue 14:00│ row idle (sched, when-chip)
│ ○  Skin export — JSON schema       30m    │
│   …on hover: Plan ›  ⇧⇩×    (or)  ↻ ✗    │ row hover (revealed)
│   …                                       │
├───────────────────────────────────────────┤
│ 🌅 Tomorrow: 3 tasks lined up      →      │ tomorrow-banner
├───────────────────────────────────────────┤
│ +  Add task…                          ›   │ composer (quiet idle)
└───────────────────────────────────────────┘
```

Selection state: `composer` swaps with `sel-bar`
(`Schedule` primary · `+1d` · `+7d` · ❄ · 🗑).

Empty state (`activeTasks.isEmpty`): replace the list with the
celebratory illustration (`bb-empty` in mockup) — owl + halo + confetti
+ «Inbox zero — nice work». `tomorrow-banner` stays.

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Mega-rows above list | up to 7 | 3 (scope+verdict / tip / segment) |
| Capacity surface | ring + ETA + pill | one text sentence |
| Suggestion surface | banner + smart-actions duplicate | one `tip-row`, two states |
| Filter axes | 4 (urgent · smart · project · colour) | 2 (segmented {all/sched/done} + source-picker) |
| Optimizer entry | 4 buttons | 1 — `Plan` in `tip-row`, two states |
| Task row meta (idle) | duration + when + per-row buttons always visible | one chip only (when-chip if sched, else faint duration) |
| Task row meta (hover) | same as idle (no reveal) | `Plan ›` OR `↻/✗` toolbar appears; meta dims |
| Tap on row | inline edit | **open question** — see `task-details.md` §5 |
| Tomorrow link | none | `tomorrow-banner` under list |

## 4. Acceptance criteria

### Meta band

- [ ] Remove `ring-mini` from scope-row; keep only the
      `Done by HH:MM · all fits inside today` sentence (or
      `· N don't fit` when `overflowingTaskCount > 0`)
- [ ] `tip-row` always occupies its slot. Two states:
      `✨ 1 task ready · <name>` + filled `Plan` pill (active suggestion),
      `✨ Plan all N tasks` + filled chevron (no suggestion)
- [ ] Segmented control has **three** chips: `All N · Scheduled N · Completed N`.
      Filter is a single `data-filter` attribute on the popover root
      (mockup CSS `:1328–1337`); completed rows stay in the same list
      and are hidden by the filter, restorable by tapping `Completed`
- [ ] Remove `BacklogActiveFilterSummaryRow`, `BacklogSmartFilterRow`,
      `BacklogFilterChipsRow`. Source-picker stays as a pill on the
      right side of scope-row

### Task row

- [ ] **Idle** row anatomy: `checkbox · title · meta · when-chip?`.
      Nothing else visible
- [ ] Trailing meta is **one** chip: `📅 Day HH:MM` if scheduled
      (calendar-coloured `when-chip` from CSS `:1412–1422`),
      otherwise faint duration mono. Never both
- [ ] Title can wrap to two lines; remove truncation
- [ ] Hotkey digits 1–9 visible as faint monospace numerals on the
      leading edge of the first 9 visible rows
- [ ] **Hover / focus-within** reveals affordances (mockup CSS
      `:1107–1115, 1118–1140, 1372–1402` — idle `opacity: 0`,
      `max-width: 0`; reveal animates to `max-width: 80pt`):
      - Unscheduled rows: `Plan ›` button + `↑ ↓ ×` cluster
      - Scheduled rows: `↻ Reschedule · ✗ Unschedule` toolbar
        replaces the `when-chip`
      - On unschedule, the row reverts: `when-chip` removed,
        calendar-colour stripe removed, `Plan ›` re-injected
        (matches mockup JS `:3168–3191`)
- [ ] Drag for reorder stays as the primary gesture. The `↑ ↓ ×`
      hover cluster is a fallback for keyboard / accessibility
- [ ] Tap on row gesture — see `task-details.md` §5
      (selection vs push-to-details)

### Composer

- [ ] Idle: grey outline, no glow, no hint-row
- [ ] Focused: accent outline, hint-row visible
      (`↩ Add · ⇧↩ Details · ⎋ Cancel`)
- [ ] Live parser chip on the right of the input shows
      `BacklogTitleParser.parse` result as a faint pill
      (`~30 min`, `P2`) — already computed in
      `BacklogFullscreenView.swift:502`

### Selection state

- [ ] `Schedule` button in `BacklogBulkActionsToolbar` rendered as
      filled primary — visually dominant over `+1d / +7d / ❄ / 🗑`
- [ ] Add a master complete-toggle (`sel-complete`) to the left of
      the `N selected` counter. Three states (mockup CSS
      `:1339–1362`, JS `:3145–3166`):
      - `none` — empty square, 1.5 pt border
      - `mixed` — green fill with a single horizontal white bar
        (indeterminate — some selected rows complete, some not)
      - `all` — green fill with checkmark
      Tapping toggles: all complete → all incomplete; otherwise →
      all complete. Lands in an undo toast

### Empty state

- [ ] When `activeTasks.isEmpty`, replace the list region with:
      owl + halo + `Inbox zero — nice work` + sub-copy
- [ ] `tomorrow-banner` remains under the empty card
- [ ] Composer remains pinned to the footer; ⌃⇧⌘Space hint optional

### Tomorrow banner

- [ ] New component `BacklogTomorrowBanner` — visible iff
      `BacklogService` has any task with `scheduledDate` falling in the
      next 24 h that isn't part of the current visible set
- [ ] Tapping the banner opens tomorrow's day view (or navigates the
      timeline; concrete routing decided in `today.md`)

## 5. Out of scope

- **Quick Capture overlay (⌃⇧⌘Space).** Solves J1 outside the popover.
  Drafted in `quick-capture.md` (Tier 1).
- **Drag-onto-timeline-slot.** Best fits in `today.md` (where the
  timeline lives), not Backlog.
- **Streak / stat-pills in inbox-zero.** Gamification is a product
  decision that `PRINCIPLES.md` doesn't yet cover. Discuss separately.
- **Source-picker UX.** Becomes interesting when there are 10+ projects
  or Apple Reminders lists. Until then: a pill that opens a menu.
- **Live optimizer ghost on row focus.** Possible once `Plan` in
  `tip-row` is in place; defer to a follow-up.
- **Replacing `EditTaskView` entirely** with the new Task Details
  surface. Migration is its own task — see `task-details.md`.
