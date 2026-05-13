# Fullscreen meeting alert

> The defining feature of Bubo. Before a meeting starts, the entire
> screen darkens with a countdown — you can't tab-switch your way past
> it. The reason your kid's daycare pickup still happens.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| A1 | Я в потоке за 5–10 минут до встречи | Невозможно проигнорировать сигнал | Не пропустить встречу |
| A2 | Я в Zoom/Teams full-screen | Алерт пробивает поверх | Не быть запертым внутри другого приложения |
| A3 | Встреча через 2 минуты | Один клик — я в Zoom | Не искать ссылку в почте |
| A4 | Не готов через 2 минуты | Snooze ещё на 2 | Сообщить себе позже |
| A5 | Это знал и так | Skip без consequences | Не превращать алерт в шум |
| A6 | Встреча 3-я за час, забыл повестку | Глянуть прикреплённый док | Не идти вслепую |

## 2. Current state

### Files

- **Alert view** — `Bubo/Presentation/Views/FullScreenAlert/FullScreenAlertView.swift:1–360`
- **App-level mount** — `Bubo/Composition/AppDelegate/AppDelegate+Alerts.swift:1–212`
- **Scheduler** — `Bubo/Infrastructure/Notifications/NotificationScheduler.swift:1–363`

### Anatomy today

`FullScreenAlertView` darkens the screen with a material overlay
plus skin-tinted radial gradient (`:45–63`). Renders:

1. Live countdown (per-second `TimelineView`); switches weight/color
   to bold/red under 5-min threshold
2. Meeting title
3. Time / location line
4. Three buttons: `Join` / `Dismiss` / `Snooze` (skin-accent style)

`NotificationScheduler` fires per-event timers based on user
reminder intervals (default 5 min). On fire, it posts
`.showFullScreenAlert`. `AppDelegate+Alerts` catches it and builds
an `NSWindow` at `.screenSaver` level so it draws above fullscreen
Zoom / Teams. Auto-dismisses at `event.startDate`.

### Known failures

- **F1 (A1).** Countdown weight/colour transition is the only escalation
  signal. The mockup escalates **the ring itself** — colour drifts from
  orange to red as the meeting nears, and the ring radius (180 pt) is
  larger than the current readout, making the alert legible across the
  room from a peripheral glance
- **F2 (A4, A5).** `Snooze` and `Skip` are different verbs — current
  view has `Dismiss` and `Snooze` but no quick `Skip ⎋` hotkey label
  in the chrome. Users dismiss-by-keyboard via Esc without realising
  it counts as «handled»
- **F3 (A3).** `Join` is generic — doesn't carry the platform
  (Zoom / Meet / Teams). The mockup labels it `Join Zoom`, with a
  platform icon
- **F4 (A6).** Stacked reminders («Reminder 2 of 3 · 30 / 10 / 2 min
  before») are not surfaced. The user has no clue this is the
  second-of-three pre-warnings
- **F5 (A6).** Attached documents / agenda preview affordance does
  not exist. Mockup shows an `agenda preview ▸` link bottom-right —
  a one-click peek at the meeting description / linked docs before
  joining

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2622–2690`

### Anatomy (target)

```
┌─────────────────────────────────────────────────────┐
│ BUBO · MEETING ALERT              [Skip ⎋]          │ topbar
│                                                     │
│                    ╭───────────╮                    │
│                    │           │                    │
│                    │   1:24    │   countdown ring   │
│                    │ UNTIL START                    │
│                    ╰───────────╯                    │
│                                                     │
│            Sprint planning · Design review          │ title
│           ⏱ 14:00 — 14:45 · 👥 5 attendees · 📹 Zoom│
│                                                     │
│    ┌──────────────┐  ┌───────────┐  ┌───────────┐   │
│    │ 📹 Join Zoom │  │🌙 Snooze 2m│ │ Dismiss   │   │ actions
│    └──────────────┘  └───────────┘  └───────────┘   │
│                                                     │
│ 🔔 Reminder 2 of 3 · stacked 30/10/2  📎 3 docs · ▸ │ bottom strip
└─────────────────────────────────────────────────────┘
```

### Key visual elements

- **Background** — radial gradients at 30 % 20 % (orange tint, 18 %)
  and 70 % 80 % (accent tint, 22 %) over a near-black linear
  gradient `#0e0e12 → #1a1a22`. Plus 30 pt drop-shadow at 55 %.
  The «room-dimming» effect that earns the alert its weight
- **Countdown ring** — 180 × 180 SVG, 6 pt stroke, dasharray-based
  progress, gradient `system-orange → system-red` rotated −90°.
  Number `1:24` at 38 pt 800-weight tabular-nums; `UNTIL START`
  label at 10 pt 600-weight tracking
- **Title** — 26 pt 700-weight rounded, max-width 540 pt,
  `text-wrap: pretty`
- **Meta line** — 13 pt 500-weight with three groups
  separated by `·` faded interpuncts: clock + time, users +
  attendee count, video + platform name (platform-coloured)
- **Buttons** — three flex-row buttons centred:
  - `Join Zoom` (primary): linear-gradient `#5fa9ff → #2d7ad6`,
    14 pt 700-weight, 11 / 22 pt padding, 12 pt radius, accent
    shadow at 40 % opacity
  - `Snooze 2m`: glass — `rgba(255,255,255,0.08)` background,
    0.5 pt border, 13 pt 600
  - `Dismiss`: even quieter — `rgba(255,255,255,0.04)` background
- **Skip button** top-right — pill, `rgba(255,255,255,0.08)`
  background, with `⎋` mono keyhint inline
- **Bottom strip** — 10.5 pt 500-weight at 45 % opacity. Two
  spans: «`🔔 Reminder N of M · stacked 30/10/2 min`» on the left,
  «`📎 N attached docs · agenda preview ▸`» on the right

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Countdown visualisation | text only, weight transition | 180 × 180 ring + text inside, orange→red gradient as time drains |
| Skip affordance | ⎋ works silently | explicit `Skip ⎋` pill top-right |
| Join label | generic «Join» | platform-aware «Join Zoom / Meet / Teams» + icon |
| Reminder context | absent | bottom-strip «Reminder N of M · 30/10/2» |
| Agenda preview | absent | bottom-strip «N attached docs · agenda preview ▸» (push to a sub-sheet) |
| Background depth | flat dim | two radial gradients (orange + accent) over near-black |
| Button hierarchy | three accent buttons | one primary + two quiet — explicit primary |

## 4. Acceptance criteria

### Countdown ring

- [ ] Replace the text-only countdown with a 180 × 180 SVG ring
      in `FullScreenAlertView.swift` (`:45–63` area)
- [ ] Stroke 6 pt, `stroke-linecap: round`, dasharray-based
      progress driven by `(eventStartDate − now) /
      reminderLeadTime`
- [ ] Gradient stops: `system-orange` at 0 %, `system-red` at
      100 %. Apply the gradient via `LinearGradient` in SwiftUI
- [ ] Time text inside the ring: 38 pt rounded 800-weight,
      tabular numerals, format `M:SS` under 1 h, `MM:SS` from
      then. Sub-label `UNTIL START` at 10 pt 600-weight tracking
      `.14em`
- [ ] Under 60 s, the ring **pulse**-attenuates every 2 s; the
      number itself does not bounce (annoyance > delight)

### Skip button

- [ ] Top-right `Skip ⎋` pill — `rgba(255,255,255,0.08)`
      background, 0.5 pt border, 11 pt 600 rounded. ⎋ key still
      works; the visible button just teaches the gesture
- [ ] `Skip` and `Dismiss` are different verbs in the AppDelegate
      hander: `Skip` records «I saw it, drop this reminder
      stack»; `Dismiss` closes the current alert but allows the
      next stacked reminder to fire (if there is one)

### Platform-aware Join

- [ ] Detect `event.conferencingURL` host and map to
      `MeetingPlatform.{zoom, meet, teams, generic}`
- [ ] Button label becomes `Join Zoom` / `Join Meet` / `Join
      Teams` / `Join`. Leading icon is the platform glyph (SF
      Symbol `video` for generic; brand-coloured chip if Zoom /
      Meet / Teams)
- [ ] Primary-button background uses platform tint when known
      (Zoom `#2D8CFF`, Meet `#00897B`, Teams `#6264A7`); falls
      back to accent

### Bottom strip

- [ ] Two-column 10.5 pt 500-weight row at 45 % opacity, pinned
      18 pt from the bottom edge
- [ ] Left: «`Reminder N of M · stacked 30 / 10 / 2 min`».
      Pulls from `NotificationScheduler` — needs a method to
      report «which lead-time is firing» and «how many in the
      stack»
- [ ] Right: «`📎 N attached docs · agenda preview ▸`» — visible
      iff `event.notes.containsURLs` OR `event.attachedFileCount > 0`.
      Tapping pushes a sub-sheet that renders the notes /
      agenda; the alert stays beneath, dimmed

### Background depth

- [ ] Two radial-gradient layers (orange 18 %, accent 22 %) over
      a linear `#0e0e12 → #1a1a22` base. Drop-shadow 30 pt at
      55 %
- [ ] Skin can override the accent tint but not the orange
      (semantic — escalation cue, `PRINCIPLES.md §7`)

### Stack handling

- [ ] If a stacked reminder fires while a previous one is still
      open (user hasn't pressed anything), replace in place with
      a `motionAware` cross-fade — do **not** stack two windows.
      The previous one is implicitly «handled» by the new fire
- [ ] Auto-dismiss at `event.startDate` stays

## 5. Out of scope

- **Agenda preview sub-sheet content.** First PR adds the entry
  point in the bottom strip but routes to a placeholder
  `AgendaPreviewView`. Markdown rendering / linked-doc previews
  is a follow-up
- **Snooze custom intervals.** Mockup shows `Snooze 2m`. Keep
  that as the single default; a Snooze-menu is out of scope
- **Reduce-motion ring.** Under `Reduce Motion`, the pulse goes
  away; the ring still renders but doesn't redraw per-second —
  it redraws on lead-time milestones (30 / 10 / 2 / 0 min). Less
  CPU, same information
- **Multi-monitor placement policy.** Where the alert appears on
  multi-display setups is its own decision — defer
- **Reschedule from alert.** «Push the meeting 15 min» from the
  alert itself would be powerful for the optimizer integration,
  but the alert's job is «remind, then yield» — adding
  scheduling controls dilutes that. Optimize via the
  `Reschedule conflict` smart-action in the popover
