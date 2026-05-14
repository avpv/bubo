# Bubo Menu-Bar Popover — Prototype Design Specification

Source: `a0fcc702-index3.html` (the third-pass HTML prototype, 3900 lines). This spec is the authoritative reference for the Swift / SwiftUI refactor of the menu-bar popover and its supporting surfaces. All numeric values are extracted directly from the inline `<style>` block; behavior notes come from `data-cap` captions, inline `title` attributes, and visible affordances.

The prototype links two external stylesheets we do **not** have: `colors_and_type.css` and `components.css`. Token values referenced via `var(--…)` are reverse-engineered from how they are used in the inline CSS — concrete values are given below in **Design Tokens**.

---

## Design Tokens

These values are inferred from usage in the inline `<style>` block. Where the prototype only uses a token (no definition), the value chosen below is the smallest set that produces the observed visuals.

### Foreground (text) opacity ramp

The prototype mixes `--fg-1` with transparent (`color-mix(in srgb, var(--fg-1) N%, transparent)`) for surfaces, while using `--fg-1..4` directly as text colors. The ramp is:

- `--fg-1` — **strongest** text. 100% opaque. Used for: titles (`.topbar .day`, `.bb-event .title`, `.tp-title`), focused active-state labels, primary numeric counts (`.city-chip .time`), composer input text.
- `--fg-2` — **secondary** text. Roughly **70%** equivalent contrast (think `rgba(0,0,0,0.7)` on light skin, `rgba(255,255,255,0.85)` on dark). Used for: meta lines under the day title (`.topbar .meta`), icon-button glyph color at rest, city-chip `.name`, sel-bar values.
- `--fg-3` — **tertiary** text. Roughly **45%** opacity. Used for: section heading labels (`.day-section .heading`, `.cmd-section-h`, `.tp-label`), placeholder text, time-offset strings, working-hours label, declined-event titles, footer hints.
- `--fg-4` — **divider lines** only. Roughly **12%** opacity. Used for: `wh-rule` (the 18 px line on the working-hours bookend) — `.wh-line .wh-rule { background: var(--fg-4); }`.

Translucent surface tints are produced separately with `color-mix(in srgb, var(--fg-1) N%, transparent)` at percentages 3 (subtlest tint, `.tp-actions` bg), 4 (`bb-shimmer`), 5 (most surface chips), 6 (`.color-filter` bg), 7 (kbd chip bg), 8 (`.tp-progress` bg, dividers), 10 (icon backgrounds), 12 (hover bg), 14 (separator), 18 (active hover), 22 (avatar fill).

### Accent + system colors

- `--accent` — **the user's chosen accent**. Default skin (`skin-system`) ties it to the macOS accent. Used for: primary buttons, active states (`.cmd-row[data-active]`), checkbox-on, focus-now-stripe, focus rings, link colors, the "Today" jump button, composer caret. Hover-tints derived as `color-mix(in srgb, var(--accent) N%, transparent)` at 5/8/10/12/14/18/22/24/26/30/35/38.
- `--system-blue` — `#007AFF` (literal value seen at `.stripe` inline styles). Used for the "auth bug" event, calendar-source dot, scheduled-task chip, default `--task-color`.
- `--system-green` — `#34C759` (inline). Used for: ON state (toggles), completed checkbox fill, ring progress, free-slot badges, success indicators, the "ON" pill in color-filter, primary "Schedule" CTA in task popover.
- `--system-orange` — `#FF9500` (inline). Used for: pomodoro accent (one half of gradient), "Now" badge, declined / cancelled accents, packed density indicator, RSVP chip, unscheduled task chip, conflict warnings.
- `--system-pink` — used as gradient stop partner to `--system-orange` on the pomodoro primary button (`linear-gradient(135deg, var(--system-orange), var(--system-pink))`) and bar gradients.
- `--system-purple` — `#9461EB` (inline). Used for: deep-work event color, exchange-calendar dot, scenario chips.
- `--system-red` — `#FF453A` for avatar; main use is destructive actions (delete buttons), `now-line` divider, in-call dot in Join ribbon, Leave button.
- `--system-yellow` — used as confetti accent in inbox-zero art.
- `--cal-color` — per-task / per-event scoped variable; falls back to `var(--accent)` when not set.
- `--tag-color` — per-tag scoped variable; falls back to `var(--fg-1)`.

### Surface + sizing

- `--popover-w` — fixed popover width. Inferred ≈ **360 px** (every popover sets `width: var(--popover-w)`; layout assumes vertical stacking of chips and 78 px-wide `.bb-event .time` columns with multi-chip rows fitting comfortably).
- `--popover-bg` — fallback popover background used by `.bb-empty-art .check-pill` outline (`box-shadow: 0 0 0 2.5px var(--popover-bg, #1f2024)`). The literal fallback `#1f2024` reveals: on a dark skin, the popover material reads ≈ `rgb(31, 32, 36)` under the blur. On the System skin (light) the value would be a near-white equivalent.
- `--surface-window` — the **actual popover material**, applied with `backdrop-filter: blur(40px) saturate(180%)`. Behaves as a semi-transparent fill; in SwiftUI this maps to `.regularMaterial` (or `.thickMaterial` for dark skins). On the System skin: light vibrancy. On dark skins (Coffee, Midnight): dark vibrancy. Avatar borders use `var(--surface-window)` as the punch-out color.

### Radii

- `--radius-sm` — **6 px**. Icon-button corners, small chips (`.task-pop .tp-back`, the kbd chip, `.wh-step`, segment-tab tops).
- `--radius-md` — **10 px**. Inferred from `.backlog .plan-day` and section banners.
- `--radius-lg` — **12 px** (likely 14). All popovers (`.popover { border-radius: var(--radius-lg); }`). Also used for the meeting-alert canvas, settings sub-cards, scenario cards.
- `--radius-pill` — **999 px**. City chip, color-filter, segment chip, composer outer, source-picker, `sel-group`, `tp-tag`, RSVP/free/conflict badges, primary action buttons in join ribbon.

### Shadows

- `--shadow-popover` — the global popover drop-shadow. From the bare-style overrides we can see equivalents: `0 12px 36px rgba(0,0,0,0.45)` (pomodoro, settings), `0 18px 50px rgba(0,0,0,0.55)` (command palette is heavier), `0 20px 50px rgba(0,0,0,0.45)` (join ribbon), `0 30px 80px rgba(0,0,0,0.55)` (meeting alert is heaviest). Use **`0 14px 40px rgba(0,0,0,0.40)`** as the default token.

### Typography

- `--font-rounded` — **SF Pro Rounded** (in SwiftUI: `.system(.body, design: .rounded)`). Used for almost all UI text.
- `--font-mono` — **SF Mono** (SwiftUI: `.system(.body, design: .monospaced)`). Used for: numeric times (`.city-chip .time`, `.wh-time`), kbd hints, version strings, meta counts, elapsed timers, "resets in" countdowns.
- `--weight-semibold` — **600** (when referenced explicitly, e.g. `.when-chip { font: var(--weight-semibold) 11px/1 var(--font-rounded); }`).

### Motion

- `--transition-micro` — short utility transition. From usage on hover-state changes (icon-btn, city-chip, plan-day, source-picker, sel-btn) the appropriate value is **`120ms ease`** (matching the explicit `transition: opacity 120ms ease, background 120ms ease` used elsewhere for the same role).

### Skins

The body element carries a `skin-*` class (the prototype defaults to `skin-system`). A skin is a **JSON-defined palette overlay** that may change:
- accent color
- button shape (corner radius bias) and font weight
- badge style + separator style
- `--skin-bg` — a radial-gradient tint painted into every `.popover::before` at `z-index: -1`, giving the popover a subtle accent halo at the top-left corner.

A skin **may not** change spacing, sizing, materials, or the semantic meaning of red/orange/green (see Settings · Appearance section, "What skins can change").

The `skin-system` definition is:
```css
.skin-system .popover {
  --skin-bg: radial-gradient(circle at top left,
    color-mix(in srgb, var(--accent) 10%, transparent) 0%,
    color-mix(in srgb, var(--accent)  2%, transparent) 40%,
    transparent 70%);
}
```

In SwiftUI: render this as a `RadialGradient` painted at the top-leading corner inside the popover background.

### Shared shell wrapper

Every popover lives inside a `.popover-wrap` outer that contains:
- top margin `36px` from the menubar (or `0` when stacked inside a flex row)
- the `.popover` itself
- an optional caption shown via `data-cap` content as a `::after` pseudo-element. The caption is design metadata, not user-visible chrome — but in this spec we treat each `data-cap` as the screen's "intent statement".

A pointer-triangle is drawn via `.popover-wrap.right-stack::before` — a 14×14 px square rotated 45° anchored 24 px from the right edge, 7 px above the popover, sharing the popover's blur material.

---

## 1. Today Popover

`data-cap`: "Today popover · Bubo found a Plan-able task before standup"

Entry point: clicking the menu-bar owl. This is the **flagship popover** — the multi-day timeline plus smart actions plus world clock.

### Layout skeleton

```
popover.popover (width=--popover-w, radius=--radius-lg, material=--surface-window)
├── header.topbar                       (bg = accent 5% mix, border-bottom 0.5px)
│   ├── .date
│   │   ├── .day        ("Tuesday, 6 May")
│   │   └── .meta       ("5 events · next in 5 h 18 min")
│   └── .actions
│       ├── icon-btn (chevron-left, navDay(-1))
│       ├── "Today" jump button (text, accent color)
│       ├── icon-btn (chevron-right, navDay(+1))
│       └── icon-btn (search)
├── .city-row           (horizontally scrolling, gradient mask on the right)
│   └── .city-chip × N  (one with data-here="true")
├── .smart              (smart-actions chip row, scroll-masked)
│   └── .bb-chip-row
│       ├── bb-chip[data-variant=prominent] "Reschedule conflict"
│       ├── bb-chip[data-variant=prominent] "Start Pomodoro"
│       ├── bb-chip[data-variant=quiet]     "Backlog (12)"
│       ├── bb-chip[data-variant=quiet]     "3 h free"
│       └── bb-chip[data-variant=quiet]     "More"
├── .color-filter       (inline pill containing icon, label, active dots, count, separator, free-slots toggle)
├── section.timeline-scroll  (max-height 420 px, overflow-y auto)
│   ├── .day-block (Yesterday)
│   │   ├── .day-header  (sticky)
│   │   ├── .wh-line     (working-hours start — sunrise icon, label, 09:00 button)
│   │   ├── .events
│   │   │   └── .bb-event × N  (past state → opacity 0.5)
│   │   └── .wh-line     (working-hours end — sunset icon)
│   ├── .day-block (Today)
│   │   ├── .day-header  (sticky, "Today" in --accent)
│   │   ├── .wh-line (start)
│   │   ├── .events
│   │   │   ├── bb-event[data-state=past]
│   │   │   ├── bb-event[data-state=now] (stripe = var(--accent), trail "Now" badge)
│   │   │   ├── .now-line  ("NOW · 10:48", red dashed rule)
│   │   │   ├── bb-event   (relative "in 12 min", trail join chip)
│   │   │   ├── .bb-slot   (free 45 min, plus-button)
│   │   │   ├── bb-event[data-type=travel]
│   │   │   ├── bb-event   (deep work)
│   │   │   └── bb-event   (1:1 with avatar)
│   │   └── .wh-line (end, 23:00)
│   ├── .day-block (Tomorrow)
│   ├── .day-block (Thu)
│   └── button.load-more "Load more days"
└── footer.footer
    ├── bb-btn[data-style=primary] "+ Add event"
    └── .right
        ├── bb-btn[data-style=secondary] "Tasks"
        └── bb-btn[data-style=secondary] (more-horizontal)
```

### Component breakdown

| Atom | Selector | Tokens used | Notes |
|---|---|---|---|
| popover shell | `.popover` | `--popover-w`, `--radius-lg`, `--surface-window`, `--shadow-popover`, blur 40 / sat 180 % | `border: 0.5px solid rgba(0,0,0,0.10)` |
| topbar | `.topbar` | `--accent` (5 % mix bg), `--fg-1`, `--fg-2`, `--font-rounded` | `padding: 10px 14px`, border-bottom 0.5 px `rgba(0,0,0,0.06)` |
| icon button | `.icon-btn` | `--fg-2` (rest), `--fg-1` (hover), `--radius-sm`, `--transition-micro`, accent 10 % hover bg | `28×28`, no border |
| city chip | `.city-chip` | `--radius-pill`, fg-1 5 % bg, fg-1 8 % border, `--fg-2`, `--font-rounded` 11.5/1, mono for `.time` & `.offset` | height 26 px, padding 0 10 px, gap 6; data-here adds accent 8 % bg + accent 22 % border |
| color filter pill | `.color-filter` | fg-1 6 % bg, `--radius-pill`, height 28 px, padding 5 px 10 px 5 px 9 px | inline-flex; contains `.color-dot` (10×10, inset shadow), `.cf-count` (mono 10.5/1, fg-3), `.cf-sep` (1×14 fg-1 14 %), `.cf-slots` toggle with `.cf-state` mini-pill |
| working-hours line | `.wh-line` | `--fg-3`, `--fg-4` divider, mono 11.5/1 | sunrise/sunset 13 px icon, 18 px rule, 22×22 px step buttons |
| day-header (sticky) | `.day-header` | `--surface-window` at 92 % + 20 px blur, `--fg-2`, accent for `.relday` | `padding: 6px 16px`, font 600 11/1, uppercase, letter-spacing 0.04 em |
| event row | `.bb-event` | `--fg-1` title, `--fg-3` meta, `--accent` for `.relative`, `--system-orange` "Now" badge | row padding `6px 12px 6px 0`, time column 78 px, stripe 3 px wide, body gap 3 px |
| free slot | `.bb-slot` | `--fg-2` label, `--fg-3` range, `--accent` add-btn | padding `6px 12px 6px 14px`, add-btn `24×24` round at accent 14 % |
| event variants | `.bb-event[data-type=…]`, `[data-state=…]` | — | see **States** below |
| platform chip | `.platform-chip` | fg-1 6 % bg, brand color override (`zoom #2D8CFF`, `meet #00897B`, `teams #6264A7`) | padding 1 px 5 px, radius 5 px, 0.5 px border |
| avatars | `.avatars .av` | bg = fg-1 22 %, border 1.5 px `--surface-window` | 16×16 round, -5 px overlap, `.more` is transparent fill |
| RSVP chip | `.rsvp-chip` | `--system-orange` 14 % bg / 30 % border / 100 % text | padding 2 px 6 px, radius 5 px |
| smart chip row | `.bb-chip` | (external, but observed `data-variant=prominent|quiet`, `data-size=compact`, `.badge` child) | scroll mask gradient on right |
| footer | `.footer` | accent 5 % mix bg, `--fg-1` border-top 0.06 | `padding: 10px 12px`, primary + secondary `.bb-btn` |

### Dimensions

- popover width = `--popover-w` (≈ 360 px)
- topbar padding `10px 14px`
- city-row: padding `8px 12px 0`, gap 6 px, right-edge linear-gradient mask 24 px
- smart-actions row: padding `8px 6px`, internal chip-row gap 6 px, padding `0 6px`, scroll mask 20 px
- color-filter: margin `0 12px 8px`, padding `5px 10px 5px 9px`, height 28 px, gap 8 px
- timeline `max-height: 420px` with thin scrollbar (`6px`, thumb `rgba(0,0,0,0.18)`)
- day-block: padding `0 12px`, separator between blocks `border-top 0.5px rgba(0,0,0,0.06)`, `margin-top 4px, padding-top 4px`
- day-section internal: padding `4px 12px 12px`, events gap 4 px
- now-line: red rule, padding `4px 4px`, font `600 10px/1`, letter-spacing 0.06 em, before/after flex rule height 1 px opacity 0.5
- wh-line: margin `6px 4px`, padding `0 4px`, rule width 18 px height 1 px, wh-time mono 11.5/1
- bb-event: `padding: 6px 12px 6px 0`; `.time` width 78 px, padding `2px 10px 2px 14px`, gap 2; `.stripe` 3×stretch radius 2 px; `.body` gap 3 px; title `600 13/1.3`; meta-stack row `400 11.5/1.3`
- bb-slot: padding `6px 12px 6px 14px`; label-big `600 13/1.3`; range-small `400 11.5/1.3`; add-btn `24×24`
- footer: padding `10px 12px`, gap 8 px

### States

| Selector | Effect |
|---|---|
| `.bb-event[data-state="past"]` | `opacity: 0.5`; `.relative` hidden |
| `.bb-event[data-state="now"]` | stripe colored with `var(--accent)`; trail shows orange "Now" pill |
| `.bb-event[data-state="cancelled"]` | title: line-through 1 px, `--fg-3` color; stripe → 135° diagonal stripes of fg-1 22 %; body opacity 0.62 |
| `.bb-event[data-state="declined"]` | row opacity 0.55; title line-through |
| `.bb-event[data-type="travel"]` | stripe → vertical dashed `--fg-3` 0-4 / 4-7 pattern; title `500 italic`, `--fg-2` |
| `.bb-event[data-type="reminder"]` | stripe → 3 px dotted radial pattern using `--cal-color`; title `500 12.5/1.3` |
| `.bb-event[data-allday="true"]` | range cell renders `600 11/1.2` uppercase letter-spaced label, no time range |
| `.bb-event:hover` | bg = accent 5 % mix; no border, no shadow |
| `.bb-slot:hover` | bg = accent 5 % mix |
| `.bb-slot .add-btn:hover` | bg = accent 24 % mix |
| `body[data-hide-{color}="1"]` | hides every `.bb-event[data-color={color}]` — color-filter dots flip these flags |

### Behavior notes

- The day-header is **position: sticky** at `top: 0; z-index: 2` with its own translucent backdrop (`--surface-window` at 92 % + 20 px blur).
- City row uses `mask-image: linear-gradient(...)` to fade the right edge — there is **no** visible scrollbar. Same trick on smart-actions row.
- `[data-here="true"]` (Moscow) drops the moon icon and the offset string, keeping just name + time.
- Color filter dots represent active colors. `.cf-count` shows "3 / 8". `.cf-slots[data-on]` toggles whether free-slot suggestions render, with the `ON / OFF` pill flipping between green-tinted and gray-tinted backgrounds.
- The "Now" badge is `bb-badge[data-style=filled]` colored orange; the surrounding event uses `--accent` as the stripe, not its calendar color.
- Inline relative-time string ("in 12 min") is rendered in `--accent` so the **next upcoming** event is glanceable.
- "Load more days" appears at the bottom of the infinite scroll region.

---

## 2. Backlog · Add (composer footer)

`data-cap`: "Backlog · Add — composer is the default footer"

The Backlog popover shares the popover shell but replaces almost every section with task-list machinery. The "Add" state is the **default**: the composer is visible at the bottom, no selection bar.

State switching is encoded with `data-bl-state="add" | "selected"` on the root `.popover.backlog`:
```css
.backlog[data-bl-state="add"]      [data-state-bar] { display: none; }
.backlog[data-bl-state="selected"] [data-add-bar]   { display: none; }
```

### Layout skeleton

```
popover.popover.backlog[data-bl-state="add"]
├── header.topbar
│   ├── icon-btn "← Today"  (accent text, "go back to Today popover")
│   ├── .day "Backlog"      (absolutely centered, 700 13/1)
│   └── .actions
│       └── icon-btn "More" (more-horizontal)
├── .scope-row
│   ├── .left
│   │   ├── svg.ring-mini   (22×22, fg track 10 % over fg, system-green progress)
│   │   ├── .stat "2 tasks" (600 13/1.2, fg-1)
│   │   └── .arrow-stat "→ 20:25"  (mono 11.5/1.2 fg-2, "done-by" ETA)
│   └── (right cluster)
│       ├── .source-picker "📥 All Tasks ▾"
│       └── icon-btn "Collapse" (chevron-up)
├── .done-by  "Done by 20:25 · all fits inside today"  (fg-3, 11/1.2)
├── .tip-row
│   ├── i.bulb (sparkles, --accent)
│   ├── .copy
│   │   └── .head "Free slot 09:30–10:30 — fits Group snippets"  (accent, 600 12/1.3)
│   └── button.run "Plan"  (accent text)
├── .seg
│   ├── icon-btn sort (24×24)
│   ├── bb-chip prominent compact "📥 All (2)"
│   ├── bb-chip quiet compact "✓ Scheduled (1)"
│   └── bb-chip quiet compact "○ Completed (0)"
├── .tasks (scroll y, thin scrollbar)
│   ├── .bb-task
│   │   ├── .checkbox
│   │   ├── .title "Group snippets — fix screen"
│   │   ├── .meta "1 h"
│   │   ├── .task-plan "📅 Plan ▸"   (hover-only)
│   │   └── .task-order [↑ ↓ ×]      (hover-only)
│   ├── .bb-task[data-scheduled="true"][style="--cal-color:var(--system-blue)"]
│   │   ├── .checkbox
│   │   ├── .title "Ad traffic clean-up — write up"
│   │   ├── .meta "1 h"
│   │   ├── .when-chip "📅 Tue 14:00"
│   │   ├── .task-sched [reschedule, unschedule]  (hover-only)
│   │   └── .task-order [↑ ↓ ×]                   (hover-only)
│   └── .bb-task (Skin export)
├── .tomorrow-banner
│   ├── .ico (sunrise on green 24 % bg)
│   ├── .copy (head + sub)
│   └── button.run "→ View"
└── .composer[data-add-bar]                (footer, accent 1 px border, pill)
│   ├── .plus icon (--accent)
│   ├── input "Add task…"
│   └── button.send (chevron-right in --accent ring)
└── .hints[data-add-bar]
    ├── "↩ Add"  · "⇧↩ Details"  · "⎋ Cancel"
```

### Component breakdown

| Atom | Selector | Tokens / values |
|---|---|---|
| ring-mini | `.ring-mini` | 22×22 SVG; track `rgba(0,0,0,0.10)` stroke-width 2.5; progress `var(--system-green)` linecap round; dasharray 56.5 / dashoffset 40 (here = 30 % done) |
| source-picker pill | `.source-picker` | radius pill, padding `4px 6px 4px 8px`, 0.5 px border `rgba(0,0,0,0.14)`, `rgba(255,255,255,0.5)` bg on light (skin-coffee overrides to `rgba(255,255,255,0.06)` / `rgba(255,255,255,0.14)`), font 500 11.5/1 |
| plan-day banner | `.plan-day` | margin `0 12px 8px`, padding `8px 12px`, radius `--radius-md`, accent 8 % bg, accent 22 % border, accent text, mono kbd label on right |
| tip-row | `.tip-row` | padding `6px 12px 10px`, gap 10 px, bulb is `--accent`, head text accent 600 12/1.3, body fg-3 400 11.5/1.35, run button accent text, padding `4px 6px`, hover accent 10 % bg |
| seg filter | `.seg` | padding `0 12px`, gap 4 px, mb 8 px; bb-chip compact with `.badge` count |
| tasks list | `.tasks` | padding `0 12px 12px`, gap 4 px, flex 1, overflow-y auto, thin scrollbar |
| bb-task row | `.bb-task` | position relative; `.title` flex 1 1 auto min-width 0 with ellipsis; `.meta` flex-shrink 0; hover reveals `.task-plan` / `.task-order` |
| task-plan button | `.task-plan` | accent text, 600 11.5/1, padding `4px 6px`, radius 6 px, opacity 0 → 1 on hover, transition 120 ms; hidden when `.task-order` shows |
| task-order toolbar | `.task-order` | inline-flex, padding 2 px (collapsed → max-width 0 padding 0 margin 0; expanded → max-width 80 px padding 2 px margin-left 4 px), fg-1 8 % bg, fg-1 10 % border, radius 7 px; buttons 18×20 fg-2; destructive button hover → system-red 18 % bg + system-red text |
| task-sched toolbar | `.task-sched` | accent 10 % bg, accent 28 % border, radius 7 px; buttons 20×20 accent; appears only when `bb-task[data-scheduled="true"]:hover` |
| scheduled stripe | `.bb-task[data-scheduled="true"]::before` | absolute left 4 px, top 8 px bottom 8 px, width 2 px, radius 1 px, color `--cal-color` |
| when-chip | `.when-chip` | bg = cal-color 14 % mix, fg = cal-color, font `weight-semibold 11/1`, padding `2px 6px`, radius 4 px |
| tomorrow-banner | `.backlog .tomorrow-banner` | margin `8px 12px 6px`, padding `10px 12px`, radius 10 px, bg = system-green 14 %, border 0.5 px system-green 30 %, head fg-1 700 12.5/1.2, sub fg-3 400 11.5/1.3, .ico 28×28 round system-green 24 % bg |
| composer | `.composer` | margin `auto 12px 4px`, padding `8px 6px 8px 12px`, gap 8 px, radius 999 px, 1 px accent border, bg = accent 5 % mix on `--surface-window`; .plus 18×18 accent; input fg-1 500 13/1, accent caret; .send 22×22 round, accent text, accent 1 px border, hover → accent fill + white text |
| composer hints | `.hints` | padding `4px 18px 12px`, fg-3 400 10.5/1, gap 12 px; .k is mono 10/1, fg-1 7 % bg, radius 3 px, padding `2px 4px` |

### Dimensions

- topbar: `padding 10 px 14 px`, the centered "Backlog" title is `position:absolute; left:50%; transform:translateX(-50%); font: 700 13px/1` so it stays optically centered regardless of the asymmetric "← Today" affordance on the left.
- scope-row: `padding 8px 12px 4px`, gap 8 px
- done-by: padding `0 12px 8px`, fg-3 400 11/1.2
- seg row: each chip has the `compact` size; `.badge` inside a prominent chip uses `color:white; opacity:.8`
- task row height: `padding 4 px` between rows (gap), checkbox 17×17 (see `.sel-complete`), title 500 13 (inherited 13 px line)

### States

| Selector | Effect |
|---|---|
| `.bb-task:hover` / `:focus-within` | `.task-plan` fades to opacity 1; `.task-order` slides in (`max-width: 80px`); `.meta` opacity 0.55; `.when-chip` opacity 0.55 |
| `.bb-task[data-selected="true"]` | bg = accent 8 % mix; border-color accent 35 % (when bordered) — **checkbox is NOT filled** because the checkbox is reserved for "complete" |
| `.bb-task .checkbox:hover::after` | shows a faint preview check (`fg-1 35 % border-color`) |
| `.bb-task[data-completed="true"]` | row opacity 0.5; checkbox fills system-green with white check; title line-through 1 px, color fg-2; `.task-plan` and `.when-chip` hidden |
| `.bb-task[data-scheduled="true"]:hover` | hides `.when-chip`, replaces it with `.task-sched` toolbar |
| `.popover.backlog[data-filter="all"]` | hides any `[data-completed="true"]` from `.tasks` |
| `.popover.backlog[data-filter="scheduled"]` | hides any non-scheduled and any completed |
| `.popover.backlog[data-filter="completed"]` | hides any non-completed, also hides hover toolbars |
| `data-bl-state="add"` | hides any `[data-state-bar]`; shows `[data-add-bar]` (composer + hints) |
| `data-bl-state="selected"` | hides any `[data-add-bar]`; shows `[data-state-bar]` (sel-bar) |

### Behavior notes

- The "← Today" button in the topbar navigates back to the **Today** popover (peer surface, not a modal).
- Tip-row may show different content: in the prototype's "Add" example it's "Free slot 09:30–10:30 — fits Group snippets" with a "Plan" run-button; the "Selected" example reads the same head but with "→ View tomorrow" instead. Tip head is allowed one `<b>` highlight token in accent's text color (its weight is inherited bold).
- "Done by 20:25 · all fits inside today" — the ETA forecast string is **directly fed by the scope ring**: the green portion of the ring = (scheduled / total estimated) of tasks.
- Composer keyboard hints: ↩ adds task, ⇧↩ opens full editor (see "New event / task" full editor), ⎋ cancels.
- The `.composer` `margin: auto 12px 4px` — `auto` on top means the composer sticks to the **bottom of the flex column** when the list is short (it's a flex-direction:column footer that pushes itself down).

---

## 3. Backlog · Selected (sel-bar swap-in)

`data-cap`: "Backlog · Selected — sel-bar swaps in with bulk actions"

Same shell as section 2, but `data-bl-state="selected"` swaps composer + hints out, swaps `.sel-bar` in.

### Layout skeleton (delta only)

```
popover.popover.backlog[data-bl-state="selected"]
├── (same header / scope-row / done-by / tip-row / seg / tasks / tomorrow-banner)
└── .sel-bar[data-state-bar]
    ├── .count "1 selected"  (accent text, 600 11.5/1)
    ├── .sel-group   ┃    (rounded "pill cluster" containing three buttons)
    │   ├── sel-btn[data-primary="true"]  "📅 Schedule"
    │   ├── sel-btn  "→ +1d"
    │   └── sel-btn  "→ +7d"
    ├── .sel-spacer  (flex 1)
    └── .sel-group
        ├── sel-btn  "❄ Freeze"  (title-only, icon-only)
        └── sel-btn[data-destructive="true"]  "🗑 Delete"
```

### Component breakdown

| Atom | Selector | Tokens |
|---|---|---|
| sel-bar | `.sel-bar` | `border-top: 0.5px solid rgba(0,0,0,0.08)`; bg = accent 6 % mix; padding `8px 12px`; gap 8 px |
| sel-group cluster | `.sel-group` | bg = fg-1 5 % mix; padding 2 px; gap 1 px; radius `--radius-pill` |
| sel-btn | `.sel-btn` | height 24 px; padding `0 10px`; font 500 11.5/1; fg-2 rest; radius pill; hover → accent 12 % bg + accent text |
| primary | `.sel-btn[data-primary]` | accent text by default |
| destructive | `.sel-btn[data-destructive]` | system-red text; hover → system-red 14 % bg |

### Dimensions

- sel-bar height ≈ 24 px button + 2 × 8 px padding ≈ 40 px
- buttons gap inside group = 1 px; between groups = 4 px

### States

| Selector | Effect |
|---|---|
| `.sel-btn:hover` | accent 12 % bg, accent text |
| primary | accent text always |
| destructive hover | red 14 % bg |
| `.bb-task[data-selected="true"]` | accent 8 % bg; selection drives the count |

### Behavior notes

- The selection action bar is **two semantic groups**: schedule-time-shift on the left, lifecycle (freeze, delete) on the right.
- `+1d` / `+7d` are convenience snooze offsets — they bypass the slot picker.
- The "Freeze" button (snowflake icon) locks a task at its current slot so the GA optimizer cannot move it on the next plan.
- Indeterminate / multi-state checkbox is encoded as `.sel-complete[data-state="all" | "mixed"]` — a 17×17 px rounded square (radius 5 px) with 1.5 px border (fg-1 35 %). On `all` it fills system-green with white check; on `mixed` it shows a green fill with a horizontal white bar (no check).

---

## 4. Backlog · Empty (Inbox Zero)

`data-cap`: "Backlog · Inbox zero — celebrate the empty state"

Same Backlog shell, but the task list is replaced by a **zen empty-state illustration** plus a tomorrow-peek + composer.

### Layout skeleton

```
popover.popover.backlog[data-bl-state="add"]
├── header.topbar (same as §2)
├── .bb-empty
│   ├── .bb-empty-art (160 × 96 frame)
│   │   ├── svg.confetti
│   │   │   ├── 4 colored lines (yellow, pink, blue, green)
│   │   │   ├── 4 colored dots (purple, orange, blue, green)
│   │   │   └── radial halo (green 30 % → 10 % → 0 %, 34 px radius)
│   │   ├── img.bubo  (56×56 owl, drop-shadow + bb-bob 3.6 s animation)
│   │   └── span.check-pill  (18×18, system-green bg, white check icon, 2.5 px outline = --popover-bg)
│   ├── .bb-empty-title "Inbox zero — nice work"   (fg-1, 700 14/1.2)
│   ├── .bb-empty-sub   "Everything is scheduled or done. Bubo recommends a walk before standup."   (fg-3, 400 12/1.4, max-width 260)
│   └── .bb-empty-stats
│       ├── .stat-pill "✓ 5 done today"      (system-green icon)
│       └── .stat-pill "🔥 3-day streak"      (system-orange icon)
├── .tomorrow-banner (same as §2)
├── .composer (same as §2)
└── .hints (same as §2)
```

### Component breakdown

| Atom | Selector | Tokens |
|---|---|---|
| empty container | `.bb-empty` | flex column center, padding `14px 24px 22px`, gap 8 px |
| art frame | `.bb-empty-art` | 160 × 96, relative |
| bubo | `.bb-empty-art .bubo` | 56 × 56; `filter: drop-shadow(0 4px 12px rgba(0,0,0,0.35))`; animation `bb-bob 3.6 s ease-in-out infinite` (translate Y −3 px and rotate ±2°) |
| check pill | `.check-pill` | 18 × 18 round, system-green bg, white check, `box-shadow: 0 0 0 2.5px var(--popover-bg, #1f2024)` so the badge appears to punch out of the popover |
| confetti svg | `.confetti` | absolute inset 0; 1.6 px stroke lines, 2 px filled circles; halo is a radial gradient (`bbHalo` id, 50 % radius, system-green 30 → 10 → 0 %) |
| empty title | `.bb-empty-title` | fg-1, 700 14/1.2 |
| empty sub | `.bb-empty-sub` | fg-3, 400 12/1.4, max-width 260, text-wrap pretty |
| stat pill | `.stat-pill` | inline-flex, padding `4px 8px`, radius 999 px, bg = fg-1 6 % mix, border 0.5 px `rgba(255,255,255,0.08)`, fg-2, font 600 11/1; first child icon system-green, second icon system-orange |

### Dimensions / States / Behavior

- Animation: `bb-bob` is a 3.6 s ease-in-out infinite bob; reduced-motion media query disables hover transforms (`@media (prefers-reduced-motion: reduce) { .icon-btn:hover, .bb-btn:hover, .bb-chip:hover, .color-dot:hover { transform: none; } }`).
- The state is conceptual: it's drawn whenever the backlog source has zero **non-completed** tasks. The tomorrow-banner is still visible to surface what's lined up next.
- Composer is **always** visible at the bottom, even when empty, so the user can immediately add a task.

---

## 5. Task Details popover

`data-cap`: "Task details · opens when you click a task — description, subtasks, tags, source"

A second-level popover that replaces the backlog list when a task is opened. The `--task-color` custom property drives the left hero stripe (defaults to system-blue).

### Layout skeleton

```
popover.popover.task-pop (style="--task-color: var(--system-blue);")
├── header.tp-topbar
│   ├── button.tp-back "← Backlog"   (accent text, 600 12.5/1, radius 6 px)
│   └── .tp-tools
│       ├── icon-btn "Star"
│       └── icon-btn "More"
├── .tp-hero  (the title block with the colored left bar)
│   ├── ::before  (3 px wide left stripe, --task-color)
│   ├── .tp-title  "Group snippets — fix screen overflow on dense layouts"   (700 16/1.25 fg-1, ls −0.01em)
│   └── .tp-meta-row
│       ├── tp-chip[data-when=unsched] "📅 Schedule"   (system-orange tinted)
│       ├── tp-chip "🕒 1 h"
│       ├── tp-chip "🔋 Medium energy"
│       └── tp-chip "🚩 P2"
├── .tp-body
│   ├── section.tp-section  Notes
│   │   ├── .tp-label "NOTES"
│   │   └── .tp-desc  (12.5/1.45, fg-2; `<em>` muted to fg-3 not italic)
│   ├── section.tp-section  Subtasks
│   │   ├── .tp-label "SUBTASKS"  + .tp-label-meta "2 of 4"  (mono 11/1, fg-3, no caps)
│   │   ├── tp-sub[data-done=true] × 2  (green checkbox 14×14, label line-through fg-3, est 11 mono fg-3)
│   │   ├── tp-sub × 2
│   │   ├── .tp-progress  (height 3 px, fg-1 8 % bg, system-green fill at 50 %)
│   │   └── button.tp-add-sub "+ Add subtask"
│   ├── section.tp-section  Tags
│   │   ├── .tp-label "TAGS"
│   │   └── .tp-tags
│   │       ├── tp-tag (--tag-color: system-pink)  "menubar"
│   │       ├── tp-tag (--tag-color: system-orange)  "bug"
│   │       ├── tp-tag (--tag-color: system-blue)  "ship-before-demo"
│   │       └── tp-tag (--tag-color: fg-3)  "+ Add"
│   ├── section.tp-section  Source
│   │   └── .tp-source
│   │       ├── .src-ico (22×22 fg-1 10 % bg, fg-2 icon)
│   │       ├── .src-copy
│   │       │   ├── .src-name "Notion · Skin renderer"  (fg-1 600 12/1.2)
│   │       │   └── .src-path "Sprint 21 / Polish / Open issues"  (fg-3 400 10.5/1.2)
│   │       └── .src-arrow (arrow-up-right, fg-3)
│   └── section.tp-section  Activity
│       └── .tp-activity "✨ Added 2 d ago by Bubo · edited 14:02"   (fg-3 400 11/1.3)
└── .tp-actions
    ├── tp-btn[data-primary=true] "📅 Schedule"   (system-green tinted, flex 1)
    ├── tp-btn "🌙 Snooze"   (neutral, flex 1)
    └── tp-btn[data-icon-only=true] "✓"   (30×30 fixed)
```

### Component breakdown

| Atom | Selector | Tokens |
|---|---|---|
| topbar | `.tp-topbar` | padding `10px 14px`, bg accent 5 %, border-bottom 0.5 |
| back button | `.tp-back` | accent text 600 12.5/1, padding `4px 6px`, radius 6 px, hover bg accent 10 % |
| hero | `.tp-hero` | position relative, padding `12px 14px 12px 18px`; `::before` left 0 top 10 bottom 10, width 3, radius `0 2 2 0`, bg = `--task-color` |
| tp-chip | `.tp-chip` | radius 999 px, padding `3px 8px`, font 600 11/1, fg-1 7 % bg, fg-1 10 % border, fg-2 text; `data-when=scheduled` → accent 14 / 26 / accent text; `data-when=unsched` → orange 10 / 22 / orange text |
| section | `.tp-section` | padding `10px 14px`, border-top 0.5 `rgba(255,255,255,0.04)` (except first) |
| label | `.tp-label` | 600 10/1 uppercase, ls 0.08 em, fg-3 |
| desc | `.tp-desc` | 12.5/1.45 fg-2; `<em>` is non-italic fg-3 |
| subtask row | `.tp-sub` | gap 9 px, padding `5px 0`, 12.5/1.3 fg-1; .cb 14×14 round-4-px box, fg-1 22 % border; done state fills system-green, checkmark via 4×7 white border-bottom/right wedge |
| progress bar | `.tp-progress` | height 3 px, fg-1 8 % bg, radius 2 px; fill is system-green |
| tag pill | `.tp-tag` | padding `3px 8px 3px 6px`, radius 999 px; bg = tag-color 12 %, border 0.5 tag-color 22 %, color = `color-mix(tag-color 100 %, white)` (a slight desaturation toward white for readability); 6×6 dot at tag-color |
| source card | `.tp-source` | padding `7px 9px`, radius 8 px, fg-1 5 % bg, 0.5 fg-1 8 % border; hover → accent 10 % bg |
| activity | `.tp-activity` | fg-3 400 11/1.3, sparkles icon, dot separator at opacity 0.5 |
| action bar | `.tp-actions` | padding `10px 12px`, border-top 0.5 `rgba(255,255,255,0.06)`, bg fg-1 3 % mix |
| tp-btn | `.tp-btn` | flex 1, height 30 px, padding `0 10px`, radius 8 px, fg-1 7 % bg, 0.5 fg-1 10 % border, fg-1 text, 600 12/1; hover accent 12 % bg; primary → system-green 22 % bg / 38 % border / system-green text; icon-only → flex `0 0 30px`, padding 0 |

### States

| Element | State | Effect |
|---|---|---|
| tp-chip | scheduled | accent-tinted bg + border + text |
| tp-chip | unsched | orange-tinted bg + border + text |
| tp-sub | done | green fill + line-through + fg-3 label |
| tp-btn | primary | green tint |
| tp-btn | icon-only | square 30 × 30 |
| tp-add-sub | hover | accent text |

### Behavior notes

- Single hero stripe color = task's calendar color (`--task-color`).
- Subtask progress is `done / total` rendered both as text ("2 of 4") and bar (50 %).
- `+ Add` tag is itself a tp-tag with `--tag-color: var(--fg-3)` (renders muted) and a plus icon instead of a dot.
- "Star" icon-btn presumably toggles favorite state; "More" exposes destructive / archive actions.
- The bottom action bar is the **primary task lifecycle** controller: Schedule (primary), Snooze (neutral), Mark complete (icon-only).

---

## 6. Slot Picker popover (Plan flow)

`data-cap`: "Slot picker · Plan flow — pick a time for one task"

A **dark** popover. This is one of the few surfaces with explicit `color: rgba(255,255,255,0.92)` because it always renders dark regardless of skin — it's the "find time for this task" moment and uses heavy contrast to focus attention.

### Layout skeleton

```
popover.popover.slot-pop
├── .sp-head
│   ├── (left column)
│   │   ├── .sp-task-line
│   │   │   ├── .sp-task-dot (8×8 system-blue)
│   │   │   ├── .sp-task-title "Group snippets — fix screen"
│   │   │   └── .sp-task-len "1 h"
│   │   └── .sp-meta "Today · 5 h 18 min free"  (white 55 %, white 92 % on <b>)
│   └── button.sp-done "Done"   (accent text, white 10 % bg, radius 999 px)
├── .sp-progress  (4 px, white 10 % track, accent fill at 26 %)
├── .sp-search
│   └── input "Find time…  type 'tomorrow 2pm' or '+1d'"
├── .sp-list
│   ├── .sp-section-h "TODAY · BEST FITS"
│   ├── .sp-row[data-checked]
│   │   ├── .check  (14×14 round, white 30 % border; checked → accent fill + white check)
│   │   ├── .t "09:30 — 10:30"
│   │   ├── .badge-free "free 1 h"
│   │   └── .meta "before standup"
│   ├── .sp-row "11:15 — 12:15"  with badge-free "free 1 h 45 m"
│   ├── .sp-row "16:30 — 17:30"  with badge-free + meta "after deep work"
│   ├── .sp-section-h "CONFLICTS SHOWN"
│   ├── .sp-row[data-conflict]
│   │   ├── .check (border tinted orange 50 %)
│   │   ├── .t.dim "14:00 — 15:00"
│   │   └── .badge-conflict "⚠ Deep work"
│   ├── .sp-section-h "TOMORROW"
│   ├── .sp-row "Wed · 09:00 — 10:00"  badge-free "free"
│   └── .sp-row "Wed · 13:30 — 14:30"  badge-free "free"
└── button.sp-foot "⚙ Smart slots · skip lunch · 25 m min length ▸"
```

### Component breakdown

| Atom | Selector | Tokens |
|---|---|---|
| popover | `.slot-pop` | width = popover-w, radius lg, surface-window bg with blur, 0.5 px `rgba(255,255,255,0.10)` border, white 92 % text |
| sp-head | `.sp-head` | padding `12px 14px 10px`, gap 10 px |
| task title | `.sp-task-title` | 600 13/1.2, white 92 %, ellipsis |
| task length | `.sp-task-len` | 500 11.5/1 mono, white 50 %-ish |
| meta line | `.sp-meta` | 500 12/1.2, white 55 %, `<b>` → white 92 %, tabular nums |
| done button | `.sp-done` | white 10 % bg, accent text, 600 12/1, padding `5px 11px`, radius 999 px |
| progress | `.sp-progress` | height 4 px, margin `0 14px 12px`, radius 2, white 10 % track, accent fill |
| search input | `.sp-search input` | white text, accent caret, transparent bg, 0.5 px white 10 % bottom border, padding `4px 0 8px`, font 500 13/1.2 |
| list | `.sp-list` | padding `4px 6px 4px` |
| section heading | `.sp-section-h` | 600 10/1 fg-3, ls 0.06 em, uppercase, padding `8px 10px 4px` |
| row | `.sp-row` | gap 10 px, padding `8px 10px`, radius 8 px; hover white 6 % bg |
| check | `.sp-row .check` | 14×14 round, 1 px white 30 % border; checked → accent fill + white check (4×7 px wedge); conflict → orange 50 % border |
| time text | `.sp-row .t` | 500 13/1.3, white 92 %, ellipsis, tabular nums; `.dim` → white 55 % |
| meta | `.sp-row .meta` | mono 11.5/1, white 50 %, tabular nums |
| scheduled | `.sp-row .scheduled` | mono 11.5/1, accent text |
| badge-free | `.badge-free` | system-green 18 % bg, system-green text, padding `2px 7px`, radius 999 px, 600 10.5/1 |
| badge-conflict | `.badge-conflict` | system-orange 18 % bg + orange text, same shape |
| tooltip "add" | `.sp-row .add-tip` | absolute above row, `rgba(58,58,62,0.95)` bg, white text, 500 11/1, padding `5px 8px`, radius 5, shadow `0 2px 6px rgba(0,0,0,0.30)` |
| foot | `.sp-foot` | padding `10px 14px`, border-top 0.5 fg-1 8 %, transparent bg, fg-2 500 12/1, hover → fg-1 + fg-1 5 % bg |

### Dimensions

- popover width = `--popover-w`
- progress bar 4 px, list rows 8 px vertical padding, check 14 px square
- search input bottom rule = 0.5 px white 10 %

### States

| Element | State | Effect |
|---|---|---|
| `.sp-row` | hover | white 6 % bg |
| `.sp-row[data-checked]` | check fills accent, white check appears |
| `.sp-row[data-conflict]` | check border tints orange; `.t.dim` muted |

### Behavior notes

- Header pairs task identity (color-dot + title + duration) with a "Today · 5 h 18 min free" capacity statement so you know what slack the schedule has.
- Progress bar reflects flow progress (e.g. "you've scheduled 26 % of your backlog tasks today").
- Input parses natural-language ("tomorrow 2pm", "+1d").
- Conflicts are **shown but selectable** — picking one means the user is overriding the optimizer.
- Foot reveals "Smart slots" settings (skip-lunch, min length).
- "Done" returns to the previous popover (Backlog or Task Details).

---

## 7. Pomodoro mini-window

`data-cap`: "Pomodoro · Focus timer mini-window, pinned during a session"

A separate, **floating mini-window** (not a menu-bar popover) anchored over the active workspace during a focus session. Always-on-top while running.

### Layout skeleton

```
popover.popover.pomo-pop  (width = popover-w, padding-bottom 12, fg-1 text)
├── header.pomo-head
│   ├── icon-btn "Close" (×)
│   ├── .pomo-mode "FOCUS · 1 OF 4"   (system-orange, 600 11/1, uppercase, ls 0.04)
│   └── icon-btn "Settings" (settings-2)
├── .pomo-ring-wrap
│   └── svg.pomo-ring (140×140)
│       ├── circle (track, white 8 %, sw 6)
│       ├── circle (progress, gradient orange→pink, sw 6, dasharray 364.4 / dashoffset 91 → ~75 % full)
│       ├── text.pomo-time "18:42"   (700 26/1 fg-1, tabular)
│       └── text.pomo-sub "LEFT"     (500 10/1, fg-3, uppercase, ls 0.04)
├── .pomo-task
│   ├── .cal-dot (8×8 system-blue)
│   ├── .pomo-task-title "Group snippets — fix screen"   (600 12.5/1.2 fg-1)
│   └── icon-btn "Change task" (chevron-down)
├── .pomo-controls
│   ├── pomo-btn.ghost "Skip"   (36×36 round, fg-1 6 % bg)
│   ├── pomo-btn.primary "Pause"   (52×52 round, orange→pink gradient, white icon)
│   └── pomo-btn.ghost "Stop"
└── .pomo-foot
    ├── pomo-stat "🔥 2 done today"   (orange icon)
    └── pomo-stat "☕ break in 18 m"   (blue icon)
```

### Component breakdown

| Atom | Selector | Tokens |
|---|---|---|
| popover | `.pomo-pop` | width popover-w, radius lg, surface-window, blur 40 / sat 180, border 0.5 white 10 %, shadow `0 12px 36px rgba(0,0,0,0.45)`, padding-bottom 12 |
| head | `.pomo-head` | padding `8px 10px 4px`, space-between |
| mode label | `.pomo-mode` | 600 11/1 system-orange uppercase, ls 0.04 em |
| ring wrap | `.pomo-ring-wrap` | flex justify center, padding `8px 0 4px` |
| ring | `.pomo-ring` | 140 × 140 px SVG; gradient `pomoGrad` defined inline orange→pink top to bottom |
| time text | `.pomo-time` | 700 26/1, fg-1 fill, tabular |
| sub text | `.pomo-sub` | 500 10/1, fg-3 fill, uppercase ls 0.04 |
| task card | `.pomo-task` | gap 8, padding `8px 12px`, margin `4px 12px 8px`, radius 8, fg-1 5 % bg, 0.5 px white 6 % border |
| cal-dot | `.cal-dot` | 8×8 round, color = event's calendar color |
| controls | `.pomo-controls` | flex center, gap 14, padding `4px 0 8px` |
| ghost button | `.pomo-btn.ghost` | 36 × 36 round, fg-1 6 % bg; hover fg-1 12 % bg |
| primary button | `.pomo-btn.primary` | 52 × 52 round, linear-gradient `135deg, orange, pink`, white icon, shadow `0 4px 12px color-mix(orange 40 %, transparent)`; hover scale 1.04 |
| foot | `.pomo-foot` | flex center, gap 14, padding-top 4 |
| stat | `.pomo-stat` | 600 10.5/1, fg-3, gap 4; first child icon = orange, second = blue |

### Dimensions / States / Behavior

- Ring SVG dimensions: circle r=58, cx=cy=70; circumference 2π·58 = 364.4 — dasharray matches, dashoffset 91 represents ~25 % remaining.
- Modes: "FOCUS · 1 OF 4" or "BREAK · 2 OF 4" — the prefix label color shifts to system-blue for breaks (inferred from `.pomo-stat:nth-child(2) i { color: var(--system-blue); }`).
- The transition is `transform 80ms ease, background 120ms ease` on every `.pomo-btn` — primary scales by `1.04` on hover (`transform: scale(1.04)`).
- The close button (top-left) **ends** the session; Stop button (bottom-right) stops the **round** but keeps the window open.
- Clicking the chevron next to the task title opens a small picker to switch which task is being timed without aborting the round.

---

## 8. Command Palette (⌘K)

`data-cap`: "Command palette · ⌘K, suggested actions, recent commands"

A globally-summonable dark popover. The active row uses an accent tint instead of a fg-1 hover tint — that's how the **keyboard-driven** selection is distinguished from mouse-hover selection.

### Layout skeleton

```
popover.popover.cmd-pop
├── header.topbar  (overridden: border-bottom 0.5 white 6 %)
│   ├── (absolute centered) "Command Palette"
│   ├── kbd "⌘K"  (mono 11/1 fg-3)
│   └── .actions
│       └── icon-btn "Close"
├── .cmd-search
│   ├── i (search icon, fg-3)
│   ├── input value="plan" autofocus   (transparent, 500 14/1.2 fg-1, accent caret)
│   └── .cmd-kbd "⎋"
├── .cmd-list  (max-height 380, overflow auto, padding `4px 6px 8px`)
│   ├── .cmd-section-h "SUGGESTED"
│   ├── .cmd-row[data-active]
│   │   ├── i.cmd-ico (calendar-plus, accent)
│   │   ├── .cmd-t "Plan <em>Group snippets</em>"   (em = accent 600)
│   │   ├── .cmd-meta "09:30 today"
│   │   └── .cmd-kbd "⏎"
│   ├── cmd-row "Plan all 2 backlog tasks"     · meta "auto-fit today"
│   ├── cmd-row "Start Pomodoro · Group snippets" · kbd ⌘ P
│   ├── .cmd-section-h "ACTIONS"
│   ├── cmd-row "Add task to backlog"          · kbd ⌘ N
│   ├── cmd-row "Reschedule conflict — Sprint planning"  · meta "smart"
│   ├── cmd-row "Freeze today's schedule"
│   ├── .cmd-section-h "NAVIGATE"
│   ├── cmd-row "Backlog"   · kbd ⌘ B
│   └── cmd-row "Today"     · kbd ⌘ T
└── .cmd-foot
    ├── hint "↑↓ Navigate"
    ├── hint "⏎ Run"
    ├── hint "⌘K Toggle"
    └── (right) "<owl> Bubo"
```

### Component breakdown

| Atom | Selector | Tokens |
|---|---|---|
| popover | `.cmd-pop` | radius lg, surface-window + blur, 0.5 white 10 % border, shadow `0 18px 50px rgba(0,0,0,0.55)` (heaviest) |
| search bar | `.cmd-search` | padding `12px 14px`, border-bottom 0.5 white 6 %, gap 8; input 500 14/1.2 fg-1 |
| kbd chip | `.cmd-kbd .k` | mono 10/1 fg-2, fg-1 7 % bg, 0.5 white 10 % border, padding `3px 5px`, radius 4, min-width 12, centered |
| section heading | `.cmd-section-h` | 600 10/1 fg-3, ls 0.06 em uppercase, padding `10px 10px 4px` |
| row | `.cmd-row` | gap 10, padding `8px 10px`, radius 8 |
| active row | `.cmd-row[data-active]` | bg = accent 18 % mix; icon and `<em>` highlight switch to accent |
| hover row | `.cmd-row:not([data-active]):hover` | fg-1 6 % bg |
| row title | `.cmd-row .cmd-t` | 500 13/1.2 fg-1, ellipsis; `<em>` is non-italic accent 600 |
| row meta | `.cmd-row .cmd-meta` | mono 11/1 fg-3 |
| foot | `.cmd-foot` | padding `8px 14px`, gap 12, border-top 0.5 white 6 %, bg `rgba(0,0,0,0.15)` |
| hint | `.cmd-foot-hint` | gap 4, 500 10.5/1 fg-3, with `.k` chip same as search |
| bubo brand | `.cmd-foot-bubo` | 600 10.5/1 fg-3, 11 px owl |

### Dimensions / States / Behavior

- Max list height 380 px; scroll inside.
- A single row carries an active indicator at any time — keyboard arrows shift `data-active` between rows. Enter runs.
- The active row's icon flips from fg-2 to accent (`.cmd-row[data-active] .cmd-ico { color: var(--accent); }`).
- The query "plan" filters the suggested row's `<em>` highlight tokens (`<em>` wraps the matched substring).
- Footer hints document keys for the same surface: up/down navigate, enter runs, ⌘K toggles.

---

## 9. Settings popover (and AI tab, Appearance / Skin picker)

`data-cap`s:
- "Settings · Calendars, Reminders, AI, Appearance — tabs inside the popover"
- "Settings · AI tab — Built-in proxy vs. own DeepSeek key, with live rate-limit indicator"
- "Settings · Appearance — JSON-defined skins change accent / shape / weight, but never spacing, materials, or semantic color"

### Layout skeleton (Calendars tab — default)

```
popover.popover.settings-pop
├── header.topbar (no border-bottom)
│   ├── .day "Settings"
│   └── .actions  → icon-btn "Close"
├── .settings-tabs   (position relative; border-bottom 0.5 white 6 %)
│   ├── settings-tab[data-active] "🗓 Calendars"
│   ├── settings-tab "🔔 Reminders"
│   ├── settings-tab "✨ AI"
│   ├── settings-tab "🎨 Appearance"
│   └── settings-tab "⚙ General"
├── .settings-body (padding `6px 4px 10px`)
│   ├── .settings-section "Calendar sources"
│   │   ├── row: dot blue   · "iCloud · Work" (42 events · synced 2 min ago)   + .toggle[data-on]
│   │   ├── row: dot red    · "Google · [user]" (18 events · synced 5 min ago) + .toggle[data-on]
│   │   ├── row: dot purple · "Exchange · team" (Disabled — re-auth in System Settings) + .toggle (off)
│   │   └── row: dot green  · "Bubo Local (private)" (Stored on this Mac only · invisible to coworkers) + .toggle[data-on]
│   └── .settings-section "Sync Apple Calendar"
│       └── row: "Read access" (Granted) + .val "● ON" (system-green)
└── .settings-foot  "Bubo · macOS 13+"   |   "v1.4.2 · Release notes"
```

### Layout skeleton (AI tab)

```
popover.popover.settings-pop
├── topbar  "Settings · AI Assistant"
├── tabs   (AI active)
├── body
│   ├── section "Mode"
│   │   ├── row (radio filled): "Built-in (recommended)"  hint "Bubo's hosted proxy. No key needed. Per-device rate limit."
│   │   └── row (radio empty):  "Own DeepSeek key"        hint "Direct to api.deepseek.com. Stored in Keychain."
│   ├── section "Rate limit (built-in)"
│   │   ├── big number "38" + "/50"   right-aligned countdown "resets in 4 h 12 m"
│   │   ├── progress bar (height 6 px, fg-1 8 % track, fill = linear-gradient(90deg, system-green, accent), width 76 %)
│   │   └── caption "When offline or rate-limited, the command palette falls back to local intent presets."
│   └── section "API key (own mode)"
│       └── row "DeepSeek key  sk-···········9f2c — stored in macOS Keychain"  +  bb-chip quiet compact "Replace"
└── foot  "Powered by DeepSeek · OpenAI-compatible"  |  "Privacy"
```

### Layout skeleton (Appearance tab)

```
popover.popover.settings-pop
├── topbar  "Settings · Appearance"
├── tabs   (Appearance active)
├── body
│   ├── section "Skin"
│   │   └── 2-column grid (gap 8, padding 4 0):
│   │       ├── card "System"     · gradient oklch(72% .14 245)→oklch(60% .12 280) · 2 px accent border · white title 700 13/1.1 · subtitle white 78 % 500 10/1.2 · check badge (16×16 white round, accent check) top-right
│   │       ├── card "Coffee"     · gradient #2a1a0a→#4a2a14 · 0.5 white 10 % border · title #f4d4a8 · sub #bfa388
│   │       ├── card "Midnight"   · gradient #0a1422→#143052 · title #a8d4f4 · sub #88a3bf
│   │       └── card "Paper"      · gradient #f0eee8→#e0dcd2 · 0.5 black 10 % border · title #3a2e20 · sub #8a7a60
│   ├── section "What skins can change"
│   │   ├── row "✓ Accent color · button shape · weight"    (check system-green)
│   │   ├── row "✓ Badge style · separator style"
│   │   ├── row "✗ Spacing · sizing · materials"            (× system-red, fg-3 text)
│   │   └── row "✗ Red/orange/green semantic meaning"
│   └── section "Add custom skin"
│       └── p "Drop a .json into ~/Library/Application Support/Bubo/Skins/ — it appears here on the next save."
```

### Component breakdown (shared across all settings tabs)

| Atom | Selector | Tokens |
|---|---|---|
| popover | `.settings-pop` | width = popover-w, radius lg, surface-window + blur, 0.5 white 10 % border, shadow `0 12px 36px rgba(0,0,0,0.45)` |
| tabs container | `.settings-tabs` | display flex, gap 2, padding `8px 8px 0`, border-bottom 0.5 white 6 %, position relative |
| tab | `.settings-tab` | padding `8px 10px`, radius `6 6 0 0`, font 600 11.5/1, fg-3, gap 5; active → fg-1 + fg-1 6 % bg + ::after underline (`bottom -1, left 8, right 8, height 2 px, accent, radius 2 px`) |
| body | `.settings-body` | padding `6px 4px 10px` |
| section | `.settings-section` | padding `10px 14px`; separated by `border-top 0.5 white 4 %` |
| section heading | `.settings-section-h` | 600 10/1 fg-3, ls 0.06 em uppercase, mb 8 |
| row | `.settings-row` | gap 10, padding `6px 0`, alignItems center |
| label | `.lbl` | 500 12.5/1.3 fg-1; `.hint` is `block 400 11/1.3 fg-3, margin-top 1` |
| value | `.val` | mono 12/1 fg-2, white-space nowrap |
| toggle | `.toggle` | 32 × 18 pill, white 14 % bg; ::after is 14 × 14 white round at (2, 2); active state `--on: var(--system-green)` → bg becomes green, knob shifts +14 px; transitions `bg 120ms ease, transform 140ms cubic-bezier(.4,.2,.2,1)` |
| foot | `.settings-foot` | padding `8px 14px`, border-top 0.5 white 6 %, bg `rgba(0,0,0,0.15)`, font 500 11/1 fg-3; `.ver` is mono 10.5/1 fg-3; `<a>` → accent text, no underline |
| kbd row in row | `.settings-row .kbd-row .k` | mono 10/1 fg-2, fg-1 7 % bg, 0.5 white 10 % border, padding `3px 5px`, radius 4 |
| radio (custom in AI tab) | inline `<span>` | filled: 14×14 round, accent bg, 3 px accent-30 % border ring; empty: 14×14 round, 1.5 px fg-1 22 % border |

### AI-tab specifics

- Big number: `700 22/1` fg-1 tabular for "38", followed by `500 13/1 mono fg-3` "/ 50".
- Countdown: `500 11/1 mono fg-3` "resets in 4 h 12 m", `white-space: nowrap`.
- Progress bar: height 6, radius 3, fg-1 8 % track, fill is gradient `90deg, system-green → accent` width 76 %.
- Caption: `400 11/1.4 fg-3`.

### Appearance-tab specifics

- Each skin card: padding 10, radius 10.
- The currently-active card has `2px solid var(--accent)` border and a 16×16 white check badge in the top-right with the check rendered in `--accent`.
- Inactive cards use `0.5px solid rgba(255,255,255,0.10)` (or `rgba(0,0,0,0.10)` for the light "Paper" skin).
- Titles render in 700 13/1.1, subtitles 500 10/1.2.
- "What skins can change" rows use either a green check or a red × icon. Cannot-change rows use `--fg-3` text color to de-emphasize.
- Inline `<code>` is mono 10.5/1, fg-1 6 % bg, padding `1px 4px`, radius 3.

### Behavior notes

- A "Reminders" tab is present (label exists) but its body is not shown in any prototype variant.
- Calendar source rows have a colored 10×10 round before the label that maps to the calendar's color (system-blue / red / purple / green).
- The "Sync Apple Calendar" row uses `.val "● ON"` with `color: var(--system-green)` — that's the readout form when the source is system-managed (no toggle).
- AI mode uses **custom radio buttons** (not the `.toggle`).
- Skin grid is hard-coded to four built-ins; user-added skins drop in from `~/Library/Application Support/Bubo/Skins/`.

---

## 10. Full-screen Meeting Alert (J4)

`data-cap`: "Full-screen meeting alert · the entire screen darkens before a meeting — you can't swipe it away (J4)"

The **defining feature** of the app. A near-fullscreen modal painted on a dark, gradient-tinted canvas. Aspect ratio 16:10. Max width 720 px in the prototype's wrapper (in production it covers the entire desktop).

### Layout skeleton

```
.wrap[style="width:100%; max-width:720px; aspect-ratio:16/10;
              radius:--radius-lg; border 0.5 white 8 %;
              shadow 0 30px 80px rgba(0,0,0,0.55);
              background = layered:
                radial 30 20 system-orange-18%→0,
                radial 70 80 accent-22%→0,
                linear-180 #0e0e12→#1a1a22"]
├── top bar (absolute, top 16, left 20, right 20, between)
│   ├── label "BUBO · MEETING ALERT"  (600 11/1 white 55 %, ls 0.12 em, uppercase)
│   └── button "Skip ⎋"  (rgba 8 % bg, 0.5 white 15 % border, white 75 % text, 600 11/1, padding `6px 12px`, radius 999)
├── svg countdown ring (180×180)
│   ├── track circle r=78, white 8 %, sw 6
│   ├── progress circle r=78, gradient orange→red ("alertRing"), sw 6, linecap round, dasharray 490 / dashoffset 65 → ~87 % filled
│   ├── text "1:24"   (white, 800 38/1, tabular)
│   └── text "UNTIL START"   (white 55 %, 600 10/1, ls 0.14 em, uppercase)
├── title "Sprint planning · Design review"   (white, 700 26/1.2, max-width 540, pretty wrap)
├── meta row  (gap 10, 500 13/1 white 65 %)
│   ├── "🕒 14:00 — 14:45"   (tabular)
│   ├── ·
│   ├── "👥 5 attendees"
│   ├── ·
│   └── "📹 Zoom"   (#69b6ff text)
├── actions (gap 10, margin-top 26)
│   ├── primary "📹 Join Zoom"   (radius 12, gradient `180deg #5fa9ff→#2d7ad6`, white text 700 14/1, padding `11px 22px`, shadow `0 6px 18px color-mix(accent 40 %, transparent)`)
│   ├── neutral "🌙 Snooze 2m"   (radius 12, white 8 % bg, 0.5 white 18 % border, white text 600 13/1, padding `11px 18px`)
│   └── ghost "Dismiss"   (radius 12, white 4 % bg, 0.5 white 12 % border, white 75 % text, 600 13/1)
└── footer reminder strip (absolute, bottom 18, left 20, right 20, between, 500 10.5/1 white 45 %, ls 0.04)
    ├── "🔔 Reminder 2 of 3 · stacked 30 / 10 / 2 min"
    └── "📄 3 attached docs · agenda preview ▸"
```

### Dimensions / States / Behavior

- Canvas: aspect-ratio 16 / 10, padding `36px 40px`, centered content.
- Countdown ring: r=78, circumference 490 (≈ 2π · 78 = 490.09), dashoffset 65 = 13 % remaining.
- Title 700 26/1.2 white, capped at 540 px, `text-wrap: pretty`.
- Buttons sit horizontally in a flex row, gap 10, 26 px below the meta line.
- The bottom strip exposes that this is **reminder 2 of 3** in a stacked schedule (30 / 10 / 2 min before) — Bubo intentionally fires the alert multiple times.
- Skip is **the only escape** (Escape key). There is no swipe-away on this alert.
- The radial backgrounds are layered: a warm orange glow top-left, an accent glow bottom-right, atop a near-black vertical gradient.

---

## 11. Join Ribbon (J1)

`data-cap`: "Join ribbon · floats above the call after you've joined — silent agenda + leave (J1)"

A floating pill that appears after the user joins the meeting. Always on top, never modal, minimal footprint. Hosts the in-call quick actions.

### Layout skeleton

```
.ribbon[style="display:flex; align-items:center; gap:14;
               padding 10 12 10 14; radius 999;
               background rgba(20,22,28,0.78);
               blur 40 sat 180;
               border 0.5 rgba(255,255,255,0.12);
               shadow 0 20px 50px rgba(0,0,0,0.45);
               color white; min-height 44"]
├── dot (8×8 round, system-red, with 4 px system-red-26 % halo, animation `bb-bob 2s infinite`)
├── stack (column, gap 1, ellipsis)
│   ├── title "Sprint planning · in call"   (white, 700 12.5/1.2, ellipsis)
│   └── meta  "06:42 elapsed · ends 14:45"   (white 55 %, 500 10.5/1 mono, tabular)
├── spacer (flex 1, min-width 12)
├── button "🎤❌ Mute"     (radius 999, transparent bg, 0.5 white 18 % border, white 90 % text 600 11.5/1, padding `6px 10px`)
├── button "📄 Agenda"
└── button "📞 Leave"   (radius 999, bg = color-mix(system-red 80 %, black), 0-border, white text 700 11.5/1, padding `6px 12px`)
```

### Dimensions / States / Behavior

- Min height 44 px — chosen to feel substantial enough to grab and drag.
- The red dot pulses via the same `bb-bob` keyframe (2 s loop) — repurposed for an attention-soft cue. The 4 px halo (`box-shadow: 0 0 0 4px color-mix(system-red 26 %, transparent)`) provides the visual ring without an extra DOM node.
- Mute and Agenda are **outline pills** (transparent fill, 0.5 px white 18 % border). Leave is a **filled** pill in red.
- The ribbon does not enter from below — it slides down from the top of the screen and parks itself near the menu bar.
- Two control roles only: in-call utility (mute, agenda), session exit (leave). No add-task, no settings — those are reachable via ⌘K which still works while the ribbon is open.

---

## Bonus: Menu-bar density bar (referenced for completeness)

While outside the 11-screen list, the prototype includes five menu-bar **owl-icon states** that drive the density indicator below the owl:

| State | Time + badge | Bar fill | Label |
|---|---|---|---|
| Clear (0/10) | 14:24, no badge | bar empty (fg-1 12 % full) | "CLEAR · 0/10" |
| Light (3/10) | 10:12, blue "2" badge | 30 % system-green, 70 % fg-1 12 % | "LIGHT · 3/10" |
| Full (6/10) | 09:45, blue "5" badge | 60 % `--accent`, 40 % rest | "FULL · 6/10" |
| Packed (9/10) | 08:22, orange "8" badge | 90 % system-orange, 10 % rest | "PACKED · 9/10" |
| Focus (running) | 18:42 mono orange, ring icon | 100 % gradient orange→pink | "FOCUS · 1 / 4" |

The bar is 36 px wide, 2 px tall, gap 1 px between segments. Background of the icon container is `rgba(0,0,0,0.04)` (light-mode glassy), radius 5, padding `0 6 px`, height 22.

---

## Cross-cutting implementation guidance

1. **Width is fixed.** Every popover binds to `var(--popover-w)`. Treat as a constant in SwiftUI (`let popoverWidth: CGFloat = 360`). Only the Meeting Alert and Join Ribbon deviate (alert is canvas-fill; ribbon is intrinsic-width).
2. **All popovers share a shell**: blurred material background, `--radius-lg` corner, ~0.5 px hairline border, `--shadow-popover`, an inner `--skin-bg` radial tint. Build a `PopoverShell` view that takes content as a closure.
3. **Hover affordances are opacity-driven, not display-toggled.** `.task-plan` fades from `opacity: 0` to `1`; `.task-order` slides in with `max-width 0 → 80 px` + `padding 0 → 2 px`. In SwiftUI, this maps to `.opacity` + `.frame(maxWidth:)` animated with `0.12 s ease`.
4. **All keyboard hint chips share one component** (mono 10/1, fg-2, fg-1 7 % bg, 0.5 px white-10 % border, radius 4, padding `3px 5px`, min-width 12, centered).
5. **The checkbox is reserved for "complete".** Selection (in backlog) does **not** fill the checkbox; it tints the row background to accent 8 %. This is a hard product rule encoded in CSS comments — preserve it.
6. **Variable-driven colors** (`--cal-color`, `--task-color`, `--tag-color`) are per-instance custom properties. In SwiftUI, pass these as parameters to row / chip views; they all fall back to either `--accent` or `--fg-1`.
7. **Past events use a single rule:** `opacity: 0.5` + hide the relative-time string. Don't reach for separate gray colors.
8. **Cancelled, declined, travel, reminder** each use a distinctive stripe pattern (diagonal stripes, full row fade, vertical dashes, dotted column) — in SwiftUI these become four `Shape` variants applied to the stripe view.
9. **The `bb-bob` keyframe** (`translateY(0)/(-3px)` + `rotate(-2°)/(2°)`, 3.6 s) is reused for the empty-state owl. A faster 2 s version with no rotation drives the Join-ribbon's red dot. Respect `prefers-reduced-motion` — the prototype disables transform hover under that media query.
10. **Day-headers are sticky** with their own translucent backdrop (92 % surface-window + 20 px blur). In SwiftUI use `LazyVStack` pinned headers with a `.background(.ultraThinMaterial.opacity(0.92))` style.
