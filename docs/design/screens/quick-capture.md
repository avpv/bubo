# Quick Capture

> Глобальный hotkey ⌃⇧⌘␣ открывает однострочный input поверх всего
> macOS. Самый дешёвый путь сбросить мысль в систему — даже из
> приложения, в котором Bubo не запущен на переднем плане.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| Q1 | Появилась мысль в Zoom-звонке | Сбросить в backlog без переключения окна | Не разрушать поток встречи |
| Q2 | Нашёл что-то в браузере | Захватить заголовок + время в одно действие | Не открывать менюбар |
| Q3 | Нужно больше полей, чем «название» | Шифт-ввод откроет полную форму | Получить детали без второго прохода |
| Q4 | Передумал | Esc мгновенно закрывает | Не оставлять полу-захваченный мусор |

## 2. Current state

### Files

- **AppDelegate bridge** — `Bubo/Composition/AppDelegate/AppDelegate+QuickCapture.swift:1–225`
- **View** — `Bubo/Presentation/Views/QuickCapture/QuickCaptureView.swift:1–123`

### Anatomy today

⌃⇧⌘␣ глобально регистрируется через двойной монитор (local +
global event-tap). При срабатывании AppDelegate показывает
прозрачный `NSPanel` 480 × 110 pt с HUD-видом в верхней-трети
экрана, в стиле Spotlight. Внутри — SwiftUI `QuickCaptureView`
с одним `TextField`. ↩ сохраняет через `QuickCaptureBridge` →
`BacklogService`; ⇧↩ перенаправляет в menu-bar popover на
полный editor; ⎋ закрывает.

### Known failures

- **F1 (Q1, Q2).** Нет inline-parser-chip: `BacklogTitleParser`
  уже умеет вычленять длительность («fix bug 45m») и приоритет
  («... P2»), но эти сигналы не отображаются в момент набора.
  Пользователь не видит, что система поняла
- **F2 (Q1).** Hint-row над/под input отсутствует —
  `↩ Add to backlog · ⇧↩ Open full editor · ⎋ Cancel` нигде не
  показано, гесты надо помнить или гадать
- **F3 (Q3).** Top bar пустой: нет «Quick capture»-маркера
  (полезен в скриншотах + onboarding) и нет визуализации
  активного hotkey (⌃ ⇧ ⌘ ␣)
- **F4 (Q4).** Окно не запоминает позицию, если пользователь
  перетащил. Каждое открытие — top-third reset

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2716–2745`

### Anatomy (target)

```
┌────────────────────────────────────────────────────────┐
│ 🦉 QUICK CAPTURE                          ⌃ ⇧ ⌘ ␣      │ topbar
├────────────────────────────────────────────────────────┤
│ +  Draft skin export changelog▏           ~30m · P3    │ input + parser chip
├────────────────────────────────────────────────────────┤
│ ↩ Add to backlog   ⇧↩ Open full editor       ⎋ Cancel  │ hints
└────────────────────────────────────────────────────────┘
```

### Key visual elements

- **Topbar**: `🦉 QUICK CAPTURE` в uppercase 11 pt 700 tracking
  `.08em` слева; четыре mono-keycap pills справа (⌃ ⇧ ⌘ ␣) —
  напоминание о хоткее
- **Input**: `+` ico (16 pt accent) · поле в 15 pt 500 rounded
  с blinking caret (accent) · справа **parser chip** — текущий
  результат `BacklogTitleParser.parse`, в формате
  `~<duration> · P<priority>`. Серый pill 10.5 pt 600 mono,
  виден только когда парсер что-то распознал
- **Hints**: 3 пилл с keycap-стилем, label 11 pt 500 в `fg-3`.
  ⎋ прижат к правому краю (cancel — destructive, далеко от
  «add»)

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Topbar | none | `🦉 QUICK CAPTURE` label + hotkey display |
| Parser chip | invisible | inline pill, updates as you type |
| Hints | absent | 3-pill bar at bottom |
| Window position | top-third reset each open | remember last drag position per-display |
| Keycap glyphs | none | mono pills for ⌃ ⇧ ⌘ ␣ + ↩ + ⇧↩ + ⎋ |

## 4. Acceptance criteria

### Topbar

- [ ] Insert above the input: 8 / 12 / 4 pt padding row with
      «`🦉 QUICK CAPTURE`» on the left (11 pt 700 rounded,
      uppercase, tracking `.08em`, `fg-3`) and four mono pills
      on the right (⌃ ⇧ ⌘ ␣)
- [ ] Each pill: 10 pt 600 mono, `fg-2` text on
      `fg-1 7%` background, 0.5 pt border, 3 / 5 pt padding,
      4 pt radius

### Input row

- [ ] Replace the current `TextField` chrome with: 16 pt
      accent `plus` icon · 15 pt 500 rounded text · trailing
      parser chip
- [ ] Bottom border 0.5 pt `fg-1 10%` (separator from hint-row)
- [ ] Caret colour `accent`
- [ ] Parser chip: bind to `BacklogTitleParser.parse(text)` on
      every change. Format:
      - `~30 m` (under 60 min) or `~1 h 30 m` (longer)
      - ` · P2` only if parser found priority
      - Empty result → chip hidden entirely
- [ ] Chip styling: 10.5 pt 600 mono, `fg-3` text on
      `fg-1 6%` background, 3 / 6 pt padding, 5 pt radius

### Hint row

- [ ] 12 pt 500 rounded hints, `fg-3`, 12 pt gap between groups
- [ ] Left group: `↩ Add to backlog`, `⇧↩ Open full editor`
- [ ] Right (after `flex:1` spacer): `⎋ Cancel`
- [ ] Each `↩` / `⇧↩` / `⎋` glyph rendered as a small keycap
      (same style as the topbar keycaps but 2 / 5 pt padding,
      3 pt radius — smaller because the hint row is lower
      hierarchy)

### Behaviour

- [ ] `BacklogTitleParser.parse` result attached to the saved
      task: cleaned title goes to `task.title`, duration goes
      to `task.durationMinutes`, priority to `task.priority`.
      Today the AppDelegate saves the raw string — promote the
      parse result on save
- [ ] Window position remembered per display in `UserDefaults`
      key `quickCapture.windowOrigin.<displayID>`. On open:
      restore if the display still exists, otherwise reset to
      Spotlight-style top-third
- [ ] Drag-to-reposition by the topbar only (input + hints
      stay click-through to their respective controls)
- [ ] Opening while already open: re-focus + select-all in the
      existing input (don't open a second window)

## 5. Out of scope

- **AI suggestions while typing.** «Did you mean to schedule
  this for tomorrow 2pm?» tempting but blurs the line with
  the slot picker. First version: parse-time-from-title only
  (parser already supports limited NL); full AI fallback in
  a follow-up
- **Multi-line capture.** A single line is the right size for
  one thought. If the user needs more, `⇧↩` opens the full
  editor — that's the escape hatch
- **Capture-to-event** (vs capture-to-task). Mockup shows
  «Add to backlog»; event-capture has its own flow via the
  popover's `Add event`. Defer
- **Drag-and-drop into the capture field** from other macOS
  apps (Mail message → task with link, Finder file → task
  with attachment). Worth doing later
- **History / recent captures** dropdown. Not in mockup
- **Always-on-top stickability.** Quick Capture is transient
  by design; «pin to keep open» would change the surface's
  job
