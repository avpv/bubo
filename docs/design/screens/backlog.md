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
- **F6 (J6).** Per-row reorder buttons (`up / down / ×`) are always
  visible — noise. Drag already exists in `+Reorder.swift`.

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
│ ⇅  [All 2]  [Scheduled 1]                 │ segmented
├───────────────────────────────────────────┤
│ ○  Group snippets — fix screen      1h    │ row (unsched, parser-meta)
│ │ ○  Ad traffic clean-up      📅 Tue 14:00│ row (sched, when-chip)
│ ○  Skin export — JSON schema       30m    │
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
| Filter axes | 4 (urgent · smart · project · colour) | 2 (segmented + source-picker) |
| Optimizer entry | 4 buttons | 1 — `Plan` in `tip-row`, two states |
| Task row meta | duration + when + per-row actions | one chip (Plan ▸ OR when-chip) |
| Tap on row | inline edit | push to Task details |
| Tomorrow link | none | `tomorrow-banner` under list |

## 4. Acceptance criteria

### Meta band

- [ ] Remove `ring-mini` from scope-row; keep only the
      `Done by HH:MM · all fits inside today` sentence (or
      `· N don't fit` when `overflowingTaskCount > 0`)
- [ ] `tip-row` always occupies its slot. Two states:
      `✨ 1 task ready · <name>` + filled `Plan` pill (active suggestion),
      `✨ Plan all N tasks` + filled chevron (no suggestion)
- [ ] Segmented control has two segments only: `All N · Scheduled N`.
      Completed-today access moves to the `⋯`-menu in topbar
      (`Show completed today`)
- [ ] Remove `BacklogActiveFilterSummaryRow`, `BacklogSmartFilterRow`,
      `BacklogFilterChipsRow`. Source-picker stays as a pill on the
      right side of scope-row

### Task row

- [ ] Trailing meta is **one** chip: `📅 Day HH:MM` if scheduled,
      otherwise duration (when no suggestion is firing) or nothing
- [ ] Title can wrap to two lines; remove truncation
- [ ] Hotkey digits 1–9 visible as faint monospace numerals on the
      leading edge of the first 9 visible rows
- [ ] Drop the per-row `up / down / ×` cluster. Drag stays. Up/down/
      delete move to the row context menu
- [ ] Tap on row pushes `TaskDetailsView` (see `task-details.md`)

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
