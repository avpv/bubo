# Command palette

> ⌘K. The «I know what I want, let me type it» surface. Lives above
> every other view, returns ranked suggestions, runs the GA on ↩.
> The keyboard-first counterpart to the menu-bar popover's mouse-
> first chips.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| K1 | Знаю команду наизусть | Запустить её за два нажатия (⌘K + 2 буквы) | Не лезть в меню |
| K2 | Знаю, что хочу, не знаю как назвать | Ввести намерение прозой, получить релевант | Не быть привязанным к терминологии |
| K3 | Накопил конфликтов | Увидеть suggested-actions сверху | Получить совет без поиска |
| K4 | Хочу повторить вчерашнее | Recent commands | Не вспоминать имя |
| K5 | Власть-юзер | Открыть Power Mode и точечно править GA | Управлять оптимизатором без визуальной возни |

## 2. Current state

### Files

- **Root** — `Bubo/Presentation/Views/CommandPalette/CommandPalette.swift:16–788`
- **Power Mode (intent composer)** — `Bubo/Presentation/Views/CommandPalette/CommandPalette+PowerMode.swift:1–216`
- **Actions** — `Bubo/Presentation/Views/CommandPalette/CommandPalette+Actions.swift:1–173`
- **Status** — `Bubo/Presentation/Views/CommandPalette/CommandPalette+Status.swift:1–134`
- **Open entry** — `BacklogFullscreenView.swift:80` (`onOpenPalette` callback)

### Anatomy today

Modal fuzzy-search command launcher invoked via ⌘K. Sections
(top-down):

1. Burnout Rescue (energy-driven, top priority when fired)
2. Right Now (dynamic ranker suggestions)
3. Events (cross-cutting spotlight for calendar search)
4. Plan Today (six outcome-named presets)
5. All Intents (collapsed-by-default 50+ preset catalogue)

Search returns matches across all sections + AI fallback when
nothing matches. ↑/↓ navigate; ↩ executes; ⎋ closes. ⌥ unlocks
Power Mode to tune intents via the composer. Optional preview
shows dry-run results.

### Known failures

- **F1 (K1).** Section nesting (5 sections + sub-sections) is
  deep. The mockup has 3 flat sections (`Suggested`, `Actions`,
  `Navigate`) — the user reads top-down without scrolling
- **F2 (K2).** Search bar is functional but visually plain.
  Mockup adds a leading search icon and a trailing `⎋` keycap
  to surface the cancel gesture
- **F3 (K3).** The «Suggested» row is the right place for
  Burnout-Rescue / conflict-related actions, but it lives
  inside one of five sections rather than as the top of the
  list with its own header
- **F4 (K4).** No explicit «Recent» section — recent commands
  surface via the dynamic ranker but aren't labelled as such
- **F5 (general).** The foot bar lacks navigation hints
  (`↑↓ Navigate · ⏎ Run · ⌘K Toggle`). Discoverability cost
  for new users
- **F6 (K5).** Power Mode is good but lacks a visible entry
  point — only ⌥-modifier reveals it. See
  `intent-composer.md` for the standalone-surface argument

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2383–2451`

### Anatomy (target)

```
┌───────────────────────────────────────────────┐
│            Command Palette          ⌘K     ✕  │ topbar
├───────────────────────────────────────────────┤
│ 🔍 plan|                                   ⎋  │ search
├───────────────────────────────────────────────┤
│ SUGGESTED                                     │
│ ┌─────────────────────────────────────────┐   │
│ │ 📅 Plan Group snippets        09:30  ⏎  │   │ active row
│ └─────────────────────────────────────────┘   │
│   📆 Plan all 2 backlog tasks    auto-fit     │
│   🔥 Start Pomodoro · Group snippets   ⌘P    │
│ ACTIONS                                       │
│   ➕ Add task to backlog              ⌘N      │
│   ⚡ Reschedule conflict — Sprint pl  smart   │
│   ❄ Freeze today's schedule                   │
│ NAVIGATE                                      │
│   📥 Backlog                          ⌘B      │
│   📅 Today                            ⌘T      │
├───────────────────────────────────────────────┤
│ ↑↓ Navigate    ⏎ Run    ⌘K Toggle    🦉 Bubo  │ foot
└───────────────────────────────────────────────┘
```

### Key visual elements

- **Topbar**: title «Command Palette» centred · `⌘K` mono pill
  on the right next to `✕` close. 13 pt 700 rounded title; 11 pt
  500 mono `⌘K`
- **Search row**: leading `🔍` (14 pt `fg-3`) · text input
  (14 pt 500 rounded, accent caret) · trailing `⎋` keycap pill
- **Sections**: each section header is 10 pt 600 uppercase
  `fg-3` tracking `.06em`, 10 / 10 / 4 pt padding
- **Row**: 8 / 10 pt padding, 8 pt radius. Inactive: just
  text. **Active** (highlighted by ↑/↓): `accent 18%`
  background, accent icon. Each row: icon · title (with
  ellipsised `<em>operands</em>` in accent · 600) · trailing
  meta (mono `fg-3` 11 pt) or kbd shortcut (mono pills)
- **Foot bar**: 8 / 14 pt padding, `rgba(0,0,0,0.15)`
  background, 0.5 pt top border. Each hint is a keycap-pill +
  10.5 pt 500 label

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Sections | 5 (Burnout · Right Now · Events · Plan Today · All Intents) | 3 flat (Suggested · Actions · Navigate) |
| Search chrome | functional, plain | leading magnifier, trailing `⎋` keycap |
| Foot hints | absent | 4-hint bar (`↑↓` · `⏎` · `⌘K` · Bubo) |
| Active highlight | OS-native list selection | accent-tinted row with accent icon |
| Power Mode entry | ⌥-modifier (invisible) | a row in `Actions` named «Open intents…» |

## 4. Acceptance criteria

### Topbar

- [ ] Centred 13 pt 700 «Command Palette» title; `⌘K` mono
      label + 14 pt `✕` close icon-btn on the right
- [ ] Background subtle: `var(--accent) 5%` tint, 0.5 pt
      bottom border. Same shape as the popover topbar

### Search row

- [ ] Leading 14 pt `🔍` in `fg-3` colour
- [ ] Input: 14 pt 500 rounded, autofocus on open, accent
      caret
- [ ] Trailing `⎋` keycap pill (10 pt 600 mono, `fg-2` on
      `fg-1 7%`, 0.5 pt border, 3 / 5 pt padding, 4 pt
      radius) — clicking dismisses

### Sections (flat)

- [ ] Collapse current 5 sections into 3 flat groups:
      - **Suggested** — top-ranked dynamic items
        (Burnout Rescue, conflict resolutions, next-action
        suggestions). Always visible
      - **Actions** — verb-named commands («Add task», «Start
        Pomodoro», «Reschedule conflict»). Includes a single
        «Open intents…» row that pushes
        `IntentComposerView` (`⌘I` shortcut)
      - **Navigate** — destination jumps («Backlog», «Today»)
- [ ] Section header style: 10 pt 600 uppercase `fg-3`
      tracking `.06em`, 10 / 10 / 4 pt padding
- [ ] Sections render in priority order; sections with zero
      matches for the current query collapse to a single
      header line

### Rows

- [ ] Idle row: icon · title (with `<em>operands</em>` in
      accent 600) · meta or kbd. 13 pt 500 rounded
- [ ] Active row (`↑/↓`-focused): `accent 18%` background,
      accent icon, accent title segments
- [ ] Hover (no focus): `fg-1 6%` background
- [ ] On ↩ — execute the active row's action. AI-fallback row
      shows a sparkle icon and «Ask Bubo» label when no exact
      match

### Foot bar

- [ ] 4 hints: «↑↓ Navigate», «⏎ Run», «⌘K Toggle», and
      «🦉 Bubo» (with the owl glyph, branding mark)
- [ ] Each hint: keycap pill + 10.5 pt 500 label in `fg-3`
- [ ] `🦉 Bubo` is right-aligned (after a `flex:1` spacer)

### AI fallback

- [ ] When the query returns no matches, surface a single row
      in `Suggested`:
      «✨ Ask Bubo: «<query>»» — pressing ↩ routes the query
      to `AIRouter.dispatch(prompt:)` and shows a result
      sheet
- [ ] AI is **always** opt-in for this row — no automatic
      dispatch on every keystroke (battery + rate-limit
      concerns from `wiki/modules/optimizer.md` apply)

### Power Mode coexistence

- [ ] Pressing ⌥ while the palette is open continues to swap
      the body into the inline composer (preserve current
      behaviour)
- [ ] A new explicit `Actions › Open intents…` row also
      pushes the standalone `IntentComposerView` (`⌘I`).
      Both entries coexist while we observe which gesture
      sticks

### Open / close

- [ ] ⌘K toggles open/close globally (popover open or not)
- [ ] On open, search field gets focus, text is selected
      (allow type-to-replace)
- [ ] Esc closes; click outside closes; ⌘K closes

## 5. Out of scope

- **Multi-step commands.** «Plan all → preview → apply» is
  three steps; the palette only initiates step one and routes
  to the scenario picker for the rest. Don't try to do it all
  inline
- **Inline preview on row focus.** Tempting but heavy — every
  ↑/↓ would fire a preview pass. Defer
- **Per-row icon customisation by skin.** Icons stay system
  (SF Symbols hierarchical) for clarity. `PRINCIPLES.md §8`
- **Voice input.** Tempting on macOS Dictation; skip
- **Personal history of commands.** A «Recent» section would
  duplicate the dynamic ranker's signal — skip in v1
- **External plugins / scripts.** A palette is the natural
  surface to extend, but plugin architecture is its own
  several-week project
