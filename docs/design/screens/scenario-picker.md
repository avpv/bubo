# Scenario picker

> The screen where Bubo shows the optimizer's output as a small set of
> visibly-different plans. Where «I don't know what to do» becomes
> «which of these do I want».

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| S1 | Запустил `Plan all` | Увидеть, что предлагает GA | Не нажимать вслепую |
| S2 | Передо мной несколько вариантов | Быстро понять, чем они отличаются | Выбрать без размышлений |
| S3 | Один из вариантов почти то | Применить и доработать | Не переделывать всё |
| S4 | Не нравится ничего | Перезапустить с другими параметрами | Не застрять |
| S5 | Хочу понять, почему этот рекомендован | Прочитать кратко его «характер» | Доверять алгоритму |

## 2. Current state

### Files

- **Inline picker** — `Bubo/Presentation/Views/Components/Backlog/SmartActions.swift:363–400`
- **Service** — `Bubo/Application/Optimizer/OptimizerService.swift` with
  `appliedScenarios` array and `switchToAppliedScenario(at:)`
- **GA engine** — `Sources/Optimizer/Orchestrator/BuboOptimizer.swift`
  with MAP-Elites archive emitting up to 5×5×5 = 125 elites
- **Module docs** — `wiki/modules/optimizer.md`

### Anatomy today

There is **no standalone scenario surface**. The picker exists as an
inline widget inside `SmartActions`:

- A row of small filled/hollow circles, one per scenario in
  `OptimizerService.appliedScenarios` (typically 3–5)
- Current scenario's dot is filled accent; others hollow
- Caption: «Scenario N of M»
- Tap calls `onSwitchScenario(index)` → `OptimizerService.switchToAppliedScenario(at:)`
  which rolls back and reapplies atomically

### Known failures

- **F1 (S1).** No moment of choice. The optimizer applies its
  best-guess immediately, then offers post-hoc switching. The user
  never sees «here are the options before you commit».
- **F2 (S2).** Scenarios have no names, no shape, no semantics —
  just indices 1…N. The MAP-Elites grid (the whole point of having
  diverse elites) is invisible.
- **F3 (S2).** The «mini-timeline» preview the mockup shows —
  stacked horizontal bars coloured by calendar — does not exist as
  a component. The user must apply each scenario to see what it
  looks like.
- **F4 (S5).** No scenario carries a fitness score, behavioural
  descriptor («72 % AM», «3 focus blocks»), or recommendation
  reasoning. The GA's evaluation is opaque.
- **F5 (S4).** «Re-evolve with different intents» is not surfaced
  next to the picker — the user has to navigate elsewhere.

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2800–2921`

### Anatomy (target)

```
┌───────────────────────────────────────────┐
│ ← Cancel       Choose a plan      4 of 125│ topbar
├───────────────────────────────────────────┤
│ Bubo evolved ~6,200 schedules in 1.4 s.   │
│ Here are 4 distinctly different elites    │
│ from the MAP-Elites archive.              │
├───────────────────────────────────────────┤
│ ┌─────────────────────────────────────┐   │
│ │ 🧠 Deep-morning   [RECOMMENDED] 0.91│   │ ← scenario card
│ │ ▰▰▰▰▰▰░▰░░░░▰▰▰░░░░░▰▰              │   │   mini-timeline strip
│ │ 🎯 3 focus blocks · ⤴ 72% AM · 🌙 17:30 │
│ └─────────────────────────────────────┘   │
│ ┌─────────────────────────────────────┐   │
│ │ 🪜 Meeting-clustered            0.86│   │
│ │ ▰▰░▰▰▰▰░▰▰▰▰▰▰░░▰▰▰▰▰              │   │
│ │ 🎯 2 focus blocks · 👥 13–16 · 🌙 18:00 │
│ └─────────────────────────────────────┘   │
│ ┌─────────────────────────────────────┐   │
│ │ ⚡ Sprint-finish                 0.83│   │
│ │ ...                                 │   │
│ └─────────────────────────────────────┘   │
│ ┌─────────────────────────────────────┐   │
│ │ 🌿 Balanced spread              0.79│   │
│ │ ...                                 │   │
│ └─────────────────────────────────────┘   │
├───────────────────────────────────────────┤
│ ↻ Re-evolve   ⚙ Tweak intents     [Apply] │ footer
└───────────────────────────────────────────┘
```

### Each scenario card

- **Name** — short label generated from the elite's MAP-Elites
  descriptor (e.g. coordinate `(morning-heavy, 3-focus, early-end)`
  → «Deep-morning»). Owned by a name-table in code, not freeform
- **Icon** — fixed-per-descriptor SF Symbol
- **`RECOMMENDED` pill** — only on the top-scoring scenario
- **Fitness score** — tabular-nums monospace `0.91`. Green for top,
  fg-2 for others. Hide entirely if the user opts out of «show
  diagnostics» in settings
- **Mini-timeline strip** — horizontal stacked bar, flex-weights
  proportional to event durations, colours from calendar colour-
  tags. Total fixed height (~14 pt). Reuse from
  `Bubo/Presentation/Views/Components/DensityBar.swift` if it
  exists; otherwise a new `ScenarioStrip` component
- **Three summary chips** — focus-block count, AM%/PM% split or
  meeting cluster, end-of-day time. Chosen from a fixed vocabulary
  derived from the MAP-Elites descriptor

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Surface | inline dots in `SmartActions` | own pushed view |
| When shown | after auto-apply | before apply (preview-mode) |
| Per scenario | index N | name + icon + score + strip + 3 chips |
| Selection | tap dot → re-applies | tap card → highlights; `Apply` commits |
| Re-run | no entry | `Re-evolve` chip in footer |
| Intent tweak | no entry | `Tweak intents` chip → `IntentComposerView` |

## 4. Acceptance criteria

### Wiring change: preview-mode optimization

- [ ] New `OptimizerService.previewScenarios(request:)` → returns
      `[ScheduleScenario]` **without** applying. Existing
      `apply…` paths stay
- [ ] `Plan all` entry from Backlog (tip-row) calls
      `previewScenarios`, navigates to `ScenarioPickerView` with
      the result; `Apply` in the picker calls
      `applyPreviewedScenario(_:)`
- [ ] Inline scenario dots in `SmartActions.swift:363–400` are
      removed. The line becomes a read-out: «Active plan:
      Deep-morning · 3 of 125», tap pushes
      `ScenarioPickerView` for post-hoc browse

### New view: `ScenarioPickerView`

- [ ] Lives at `Bubo/Presentation/Views/Optimizer/ScenarioPickerView.swift`
- [ ] `init(scenarios:, recommendedIndex:, totalEvolved:, elapsed:, onApply:, onReEvolve:, onTweakIntents:)`
- [ ] Topbar: `← Cancel` · «Choose a plan» · `N of TOTAL` mono on
      right
- [ ] Intro line: «Bubo evolved ~`TOTAL` schedules in `ELAPSED`.
      Here are N distinctly different elites from the MAP-Elites
      archive.»
- [ ] Cards stacked vertically with `DS.Spacing.sm` between

### Scenario card

- [ ] One `Button` per scenario, full-width
- [ ] Selected card: 1.5 pt accent border + 10 % accent background
- [ ] Unselected: 0.5 pt hairline border + 4 % fg background
- [ ] Card content top row: icon · name · `RECOMMENDED` pill
      (only on `recommendedIndex`) · score (right, tabular-mono)
- [ ] `ScenarioStrip` (new component) — stacked horizontal bar of
      coloured segments proportional to events. 14 pt height. Empty
      flex-segments use 14 % fg as «gap» colour
- [ ] Bottom row: three summary chips from the descriptor

### Naming

- [ ] New file `Sources/Optimizer/Naming/ScenarioNamer.swift`:
      maps MAP-Elites descriptor → human name + SF Symbol +
      summary chips. Initial table: ~10 names covering common
      coordinates (`Deep-morning`, `Meeting-clustered`,
      `Sprint-finish`, `Balanced spread`, `Late-start`,
      `Block-of-blocks`, `Spread-thin`, `Front-loaded`,
      `Back-loaded`, `Mixed`)
- [ ] When no name matches the descriptor, fall back to the dominant
      axis (`Morning-heavy`, etc.)

### Footer

- [ ] `↻ Re-evolve` — quiet chip; re-runs the GA with the same
      `OptimizationRequest`, replaces the scenario list with new
      results
- [ ] `⚙ Tweak intents` — quiet chip; pushes
      `IntentComposerView` (see `intent-composer.md`); on return,
      re-evolves automatically
- [ ] `[Apply]` primary, filled accent. Disabled until the user
      has tapped a card to select one. Pressing applies via
      `OptimizerService.applyPreviewedScenario` and pops back to
      Backlog with an undo toast

### Accessibility

- [ ] Each scenario card is one VoiceOver element. Label:
      «Deep-morning, recommended, 3 focus blocks, 72 % morning,
      ends 17:30, fitness 0.91 of 1»
- [ ] Cards reachable by ↑/↓; ⏎ selects; ⌘⏎ applies

## 5. Out of scope

- **Composing scenarios** (e.g. «take morning from A, afternoon from
  B»). Tempting but a separate feature.
- **Showing > 4 elites** at once. The MAP-Elites archive has up to
  125, but reading more than ~4 is the user's job, not the
  picker's. Pagination via `Re-evolve` is the answer.
- **Diff view** between scenarios (highlight what moves between A
  and B). Powerful but its own surface.
- **Manual fitness re-weighting** inside the picker. Belongs to
  `intent-composer.md`.
- **«Why is this recommended?» expandable explainer.** Worth doing,
  but needs a careful product write-up — defer.
- **Live re-evolve** as the user types in `Tweak intents`. The first
  PR runs the GA on `Apply` of the intent composer; live runs are
  a follow-up.
