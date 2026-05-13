# Intent composer

> Place where the user composes declarative scheduling rules — «Block
> 14–17 for Deep Work», «Prioritise Project X this week», «Schedule
> the auth bug at 15:00» — that form a typed DAG feeding the GA.
> Conflicts surface *before* the optimizer runs, so the GA never
> wastes cycles on impossible instructions.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| I1 | Хочу зарезервировать окно | Создать hard-rule на время | Оптимизатор не трогал блок |
| I2 | Знаю свой ритм | Задать soft-preference (утренний фокус) | План клонился в нужную сторону, но не ломался |
| I3 | Активный проект — главный | Пометить его «×1.4 веса» неделю | Задачи проекта подтягивались первыми |
| I4 | Два правила конфликтуют | Увидеть конфликт до запуска GA | Не получать сюрприз в scenario |
| I5 | Накопил набор правил | Сохранить как preset | Не вводить заново каждое утро |
| I6 | Правило временное | Удалить за один клик | Не копить «вчерашние» правила |

## 2. Current state

### Files

- **Intent model** — `Bubo/Application/Intents/ScheduleIntent.swift:1–302`
  (65 typed cases covering time / events / weights / energy /
  stability / rules / task selection / speed / display / smart /
  social / health / context / adaptive / temporal scope / sources
  / transforms)
- **Composer UI** — `Bubo/Presentation/Views/CommandPalette/CommandPalette+PowerMode.swift:1–216`
  (only entry: `powerModeComposer` at `:17–118`)
- **Palette host** — `Bubo/Presentation/Views/CommandPalette/CommandPalette.swift:16–788`
- **DAG compile** — referenced by `IntentGraphSalsaCache` (cached
  suggestions); compile stages live in
  `Sources/Optimizer/` (expand → DAG → ports → topo → cond → GA)

### Anatomy today

There is **no standalone intent surface**. Intents are exclusively
composed inside the command palette's *Power Mode* (unlocked by
⌥). When the user presses ⌥, the palette swaps its lower body to
a `powerModeComposer` panel:

- Active intents grouped by phase
- Suggested intents from `IntentGraphSalsaCache`
- Parameter sliders (focus duration, working window, max
  meetings)
- Conflict warnings with proposed resolutions
- Dry-run preview

### Known failures

- **F1 (I1–I6).** Discoverability: intents live behind ⌥-modifier
  inside ⌘K. Two hops away from any task surface. User who
  doesn't know «Power Mode» exists will never edit a rule
- **F2 (I4).** Conflict detection runs but is buried in the
  palette body. The mockup elevates conflicts to a banner with
  three resolution chips («Drop the pin», «Shrink the block»,
  «Run anyway») — first-class
- **F3 (I4, I5).** No DAG-compile ribbon. The optimizer
  internally compiles through `expand → DAG → ports → topo →
  cond → GA`; user sees none of these stages. The mockup turns
  the pipeline into a small progress strip with green checks /
  orange warnings — diagnosable when something stalls
- **F4 (I6).** Intent removal lives inside the per-row context
  inside the palette body. No dedicated «delete» affordance
- **F5 (I5).** Preset save / load is implicit (history-based);
  no explicit «Save this set as a preset» button

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2923–3005`

### Anatomy (target)

```
┌──────────────────────────────────────────────┐
│ ←      Intents                    ▶ Run      │ topbar
├──────────────────────────────────────────────┤
│ ACTIVE · 3                              + Add│
│ ┌──────────────────────────────────────────┐ │
│ │ 🛡 Block 14:00–17:00 for Deep Work   OK ✓│ │ intent row
│ │ Hard constraint · phase: source          │ │
│ └──────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │
│ │ 📈 Prioritise Skin export this week  OK ✓│ │
│ │ Soft · weight 1.4× · phase: transform    │ │
│ └──────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │
│ │ ⏰ Schedule Ad clean-up at 15:00 ⚠ CONFLICT│ orange tint
│ │ High deadline · phase: transform         │ │
│ └──────────────────────────────────────────┘ │
├──────────────────────────────────────────────┤
│ ⚠ 1 hard conflict                            │ banner
│ «Schedule at 15:00» falls inside «Block      │
│ 14–17 Deep Work». GA cannot satisfy both.    │
│ [Drop the 15:00 pin] [Shrink Deep Work…]     │
│ [Run anyway]                                 │
├──────────────────────────────────────────────┤
│ DAG COMPILE · 8 stages                       │
│ ✓expand──✓DAG──✓ports──⚠topo──cond──GA       │
│ Resolve conflict to compile through topo-    │
│ sort and run the genetic algorithm.          │
└──────────────────────────────────────────────┘
```

### Key visual elements

- **Topbar**: `← back` · «Intents» (title) · `▶ Run` (filled
  accent pill, 24 pt height, 700 12 pt)
- **Active section header**: «`ACTIVE · N`» on the left,
  `+ Add` quiet chip on the right
- **Intent row**: 22 pt rounded icon-square in phase-tinted
  background + 13 pt 600 title (with bolded operands) + 11.5 pt
  400 meta-line (constraint type · phase) + right-side status
  pill (`OK` green / `CONFLICT` orange)
- **Conflict banner**: orange-tinted card with `⚠` icon, 12 pt
  700 title «N hard conflict», 11.5 pt body explaining what's
  wrong, three action chips (one prominent in orange tint, two
  quiet)
- **DAG ribbon**: 10 pt 600 uppercase header «`DAG COMPILE · N
  stages`», then a stage-chain. Each stage = 4 / 7 pt chip with
  status colour (`✓` green when passed, `⚠` orange when warned,
  faint grey when not yet reached). 1 pt rules between stages,
  coloured by the segment they bridge

### Diff vs current

| | Current (Power Mode in palette) | Target (standalone) |
|---|---|---|
| Entry | ⌘K → ⌥ | direct, from `⋯`-menu on Today popover · linked from `Tweak intents` in scenario picker · from `⌘I` global |
| Conflict surface | inline warning | first-class banner with action chips |
| DAG visualisation | absent | 6-stage progress ribbon |
| Preset save | implicit history | explicit `Save as preset` action in `⋯`-menu |
| Run | tied to palette commit | dedicated `▶ Run` in topbar |
| Discoverability | hidden behind ⌥ | direct entry + URL-routable for sharing |

## 4. Acceptance criteria

### New SwiftUI view: `IntentComposerView`

- [ ] Lives at
      `Bubo/Presentation/Views/Intents/IntentComposerView.swift`
- [ ] Pushed from:
      - `MenuBarView` `⋯`-menu: `Intents…`  (⌘I)
      - Scenario picker footer: `⚙ Tweak intents` chip
        (see `scenario-picker.md`)
- [ ] Reads / writes the active intent set via a new
      `IntentService` that wraps the model in
      `ScheduleIntent.swift` and persists to `UserDefaults`
      with per-day / per-week scoping

### Active section

- [ ] Header: «`ACTIVE · N`» on the left, `+ Add` quiet chip on
      the right (opens an inline picker of common intent
      templates)
- [ ] Each intent renders as a card-row:
      - Icon square in phase tint (`source` blue, `transform`
        purple, `display` green)
      - Title with operands bolded — accent colour for time
        ranges, `system-orange` for deadlines, `fg-1` for
        names
      - Meta-line: constraint type («Hard constraint» /
        «Soft preference · weight N×») · phase label in mono
      - Right pill: `OK` (green tint) or `CONFLICT` (orange
        tint)
- [ ] Tap a row to inline-edit its parameters (slider for
      weight, time-range for blocks)
- [ ] Swipe-left / context-menu `Delete` removes the intent
      with undo toast

### Conflict banner

- [ ] Visible iff `conflicts.count > 0`. Orange-tinted card
      between the active list and the DAG ribbon
- [ ] Title: «`N hard conflict`» / «`N soft conflicts`»
- [ ] Body: ≤ 3 sentences. First sentence names the two
      conflicting intents; second explains the impossibility
- [ ] Action chips (up to 3): each one is a typed resolution
      that mutates the active set when tapped — first chip
      prominent (orange tint), rest quiet
- [ ] If user dismisses without resolving, `▶ Run` becomes
      `▶ Run anyway` (orange-tinted)

### DAG compile ribbon

- [ ] Fixed 6 stages: `expand → DAG → ports → topo → cond → GA`.
      Each stage shows status:
      - `✓` green-tinted when the compiler passed it
      - `⚠` orange-tinted when it warned (continued but flagged)
      - `✗` red-tinted when it failed
      - faint grey when not yet reached
- [ ] Inter-stage rules: 1 pt line, coloured by the source
      stage's status (green / orange / red / grey)
- [ ] Caption under the ribbon explains the current state in
      one sentence («Resolve conflict to compile through
      topo-sort and run the genetic algorithm.»)

### Run

- [ ] Top-right `▶ Run` button — filled accent pill, 700 12 pt
- [ ] Disabled (`opacity: 0.4`) if any hard conflict is
      unresolved (use orange-tinted `▶ Run anyway` instead —
      single action, different label)
- [ ] On press: invokes `OptimizerService.previewScenarios(...)`,
      pushes `ScenarioPickerView`. On commit there, the
      composer pops back to the source (Backlog / Today)

### Power Mode bridge

- [ ] `CommandPalette+PowerMode` keeps its inline composer for
      «I'm already in the palette and want to tweak quickly»,
      but its `Open full composer ▸` link pushes the new
      standalone view
- [ ] First PR does not remove the inline composer — coexist
      and observe usage before deprecating

## 5. Out of scope

- **Intent presets store / share.** Saving a curated intent set
  as «My deep-work mode» and switching between presets is the
  natural next step, but a separate doc
- **Natural-language intent entry.** «Hey Bubo, block 2 to 5 PM
  for deep work» → parse to typed intent. Promising; defer
- **Versioning / time-travel** of intents. Useful but premature
- **Cross-device sync.** Intents currently live in local
  `UserDefaults`. iCloud KVS for sync is a separate
  infrastructure decision
- **Visualising the GA's own iteration.** Watching the GA
  evolve scenarios in real time would be powerful but lives
  in the scenario picker (see `scenario-picker.md` §5)
- **Per-row collapse / expand.** All intents are short enough
  that collapsing them hides nothing useful; skip
