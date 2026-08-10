# Menu-bar owl + density bar

> The 22×22 surface that lives in the macOS menu bar. The user sees it
> dozens of times a day without clicking. It must answer «how full is
> today?» before you open anything, and turn into a focus-timer when
> Pomodoro is running.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| M1 | Сел работать утром | За один взгляд понять плотность дня | Решить, тянуть ли ещё одну задачу |
| M2 | Часто проверяю время | Видеть точное время в menubar | Не дублировать системные часы (или дублировать осознанно) |
| M3 | Иду к новому собеседнику | Знать «сейчас встреча или нет» | Не врываться в чужой Pomodoro |
| M4 | Запустил Pomodoro | Видеть таймер прямо в menubar | Не открывать поповер ради секундомера |
| M5 | Хочу открыть Bubo | Кликнуть в одно место | Не искать |

## 2. Current state

### Files

- **Icon controller** — `Bubo/Composition/App/App.swift:1–225` (and
  beyond)
- **Density logic** — `:160–189` (booked-fraction → 10-bucket
  quantisation; only renders during working hours)

### Anatomy today

A 22 × 22 stylised owl drawn in CoreGraphics. Below the owl,
a thin density bar (7 % of icon height) encodes today's booked
fraction:

- Bar **length** (not colour) goes 0–70 % of icon width, in 10
  buckets
- Bucket = `bookedMinutesInWorkingWindow / workingWindowDuration`,
  clipped
- Outside working hours: bucket = 0 (bar invisible)
- Cached per `(bucket, skinID)` to avoid flicker

### Known failures

- **F1 (M1).** Length-only encoding is conservative (works for
  colour-blind users), but it gives up the **fastest signal** — a
  green-to-orange shift screams «something changed» across the
  screen. Mockup adds colour bucketing: green (light) → accent
  (balanced) → orange (packed). Encoding remains length, but
  colour earns its place when length alone is hard to read
- **F2 (M2).** Icon shows just the owl; system clock is to the
  right of it. Mockup pairs `owl + HH:MM` in one capsule —
  reduces eye travel by ~80 pt and makes «time + load» one
  glance
- **F3 (M3).** Today's event count not visible in idle. Mockup
  adds a tiny blue (or orange when packed) badge with the count
- **F4 (M4).** Pomodoro running has no signal in the menu bar.
  User must keep the Pomodoro mini-window open. Mockup replaces
  the owl with a mini ring + monospace `MM:SS` in `system-orange`,
  switching back to the owl + density on session end
- **F5 (M5).** Click is correctly bound to the popover, but
  ⌥-click / right-click have no dedicated action. Common macOS
  pattern is right-click → quick menu. Worth claiming

## 3. Target design

- **Mockup**: `ui_kits/index2.html:3006–3088` (5 states)

### Anatomy (target) — 5 states

```
┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐
│ 🦉 14:24│  │ 🦉 10:12 2│ │ 🦉 09:45 5│ │ 🦉 08:22 8│ │ ⏱ 18:42│
├────────┤  ├────────┤  ├────────┤  ├────────┤  ├────────┤
│ ▱▱▱▱▱▱ │  │ ▰▱▱▱▱▱ │  │ ▰▰▰▱▱▱ │  │ ▰▰▰▰▰▱ │  │ ▰▰▰▰▰▰ │
│CLEAR 0 │  │LIGHT 3 │  │FULL 6  │  │PACKED 9│  │FOCUS 1/4│
└────────┘  └────────┘  └────────┘  └────────┘  └────────┘
```

(The bottom labels show what each state *means*; they are not
visible in the menubar — they're shown in the click-through
help row when the user hovers / right-clicks for the tooltip.)

### Five states

| Bucket | Range | Label | Bar colour | Bar length | Badge |
|--------|-------|-------|------------|------------|-------|
| Clear  | 0/10      | CLEAR  | `fg-1 12%` (faint)         | 100 % (filled grey) | none |
| Light  | 1–4/10    | LIGHT  | `system-green`             | proportional        | event count, blue |
| Full   | 5–7/10    | FULL   | `accent`                   | proportional        | event count, blue |
| Packed | 8–10/10   | PACKED | `system-orange`            | proportional        | event count, orange |
| Focus  | Pomodoro  | FOCUS N/M | gradient orange→pink     | full + animated     | owl replaced by ring |

### Capsule

- 22 pt height, ~6 pt internal padding, `rgba(0,0,0,0.04)`
  background, 5 pt border-radius
- Contains: owl (or ring) `14 × 14` · time `HH:MM` (11 pt 600 mono)
  · optional event-count badge (9 pt 700, white-on-coloured pill,
  4 pt padding, 999 px radius)
- During Focus state, the owl-replacement ring shows lap progress
  (`dasharray` based on `(elapsed / sessionDuration)`),
  `system-orange` stroke, and the time text becomes the focus
  timer `MM:SS` in `system-orange`

### Right-click / ⌥-click menu

```
Bubo
─────────────────
○ Working hours starts 09:00
○ Working hours ends   19:00
─────────────────
Plan day…              ⇧⌘P
Start Pomodoro         ⌘P
─────────────────
Refresh
Preferences…           ⌘,
Quit Bubo              ⌘Q
```

## 4. Acceptance criteria

### Density bar

- [ ] Keep length encoding (10 buckets). Add **colour bucketing**
      on top: 0 → faint grey, 1–4 → green, 5–7 → accent,
      8–10 → orange
- [ ] `Clear` (0/10) state — the bar is fully filled at faint
      grey, not invisible. Empty days deserve a calm signal
- [ ] Bar height stays 7 % of icon height. Width 36 pt
- [ ] Render only inside the working window (existing behaviour)

### Owl + time capsule

- [ ] Pair the owl glyph with the current `HH:MM` in one capsule
      (14 × 14 owl + 11 pt 600 mono time, ~6 pt internal gap)
- [ ] Pure mono numerals, `font-variant-numeric: tabular-nums`,
      so the capsule width doesn't jitter

### Event-count badge

- [ ] Visible iff `eventsToday.count > 0` AND state ≠ `Focus`
- [ ] Position: trailing edge of the capsule, baseline-aligned
      with the time
- [ ] Colour: `system-blue` in Light/Full states,
      `system-orange` in Packed state. Text always white

### Focus state

- [ ] When `PomodoroService.isRunning == true`, replace the owl
      glyph with a 14 × 14 SVG ring:
      - 5.5 pt radius, 1.5 pt stroke, `system-orange` foreground
        over `fg-1 14%` background
      - Dasharray computed from session progress, rotated −90°
- [ ] Replace the time text with the focus timer `MM:SS` in
      `system-orange`, same font as before
- [ ] Density bar replaced by a 100 %-filled gradient
      `system-orange → system-pink`. Subtle pulse every 2 s
      (motion-aware: disable under `prefers-reduced-motion`)
- [ ] On session end / pause, smooth-revert to the previous
      state over 600 ms

### Click bindings

- [ ] Left-click — toggle the popover (existing)
- [ ] Right-click / ⌥-click — opens an `NSMenu` with the items
      listed in §3
- [ ] ⌘-click — opens the Quick Capture overlay (see Tier 1
      `quick-capture.md` when drafted)

### Caching

- [ ] Existing per-`(bucket, skinID)` cache extends to per-
      `(bucket, skinID, focusState, eventCountTier)`. Avoid
      redrawing every minute when only the time text changed —
      time updates via a separate `TimelineView`-backed `NSImage`
      layer

## 5. Out of scope

- **Per-day load preview on hover.** Hovering the menu-bar icon
  to see «tomorrow: 6/10» would be helpful but is its own
  surface. Defer
- **Click-and-hold for quick scheduling.** Tempting. Out of
  scope
- **System clock replacement.** Bubo's time is paired with the
  owl for context; users still have macOS's clock to the right.
  Hiding the system clock is a user-level decision (System
  Settings), not something Bubo touches
- **Hour-by-hour density.** Today's bar is a single number. A
  per-hour bar (24 segments) would be richer but doesn't read
  at 22 × 22. The popover's timeline is where richness lives
- **Streaks / day-completion badge.** Same gamification concern
  as `backlog.md` §5
- **Custom owl glyphs / seasonal variants.** Skins already
  carry the «mood» knob (`PRINCIPLES.md §10`). A whole owl
  rotation is over-scope
