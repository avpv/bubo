# Join ribbon

> A pill that floats above the call after you've joined. Tells you
> «yes, you're in this meeting», keeps the leave-control one click
> away, and stops the alert from re-firing for an event you're
> already attending.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| R1 | Только что нажал «Join Zoom» | Видеть подтверждение «я внутри» | Не нажимать ещё раз |
| R2 | Иду по календарю в другом приложении | Помнить, что сейчас идёт встреча | Не пропустить ответ собеседника |
| R3 | Встреча закончилась | Закрыть Zoom за один клик | Не возиться с окнами |
| R4 | Нужна тишина 30 секунд | Замьютить без переключения окна | Не светить кашлем коллегам |
| R5 | Забыл повестку | Открыть её прямо из ribbon | Не рыться в почте |

## 2. Current state

### Files

- **Ribbon view** — `Bubo/Presentation/Views/Event/JoinRibbonView.swift:1–94`
- **App-level mount** — `Bubo/Composition/AppDelegate/AppDelegate+JoinRibbon.swift`

### Anatomy today

A small floating ribbon (~36 pt) shown after the user taps
`Join …` in the fullscreen alert. Contents:

1. Checkmark + label «Joined · `<event title>`»
2. Live countdown to `event.startDate` (during the lead-time)
3. `Re-alert` button — bring back the fullscreen alert
4. `×` dismiss

Lives in its own `NSPanel` window, transparent and click-through
on the dead zones. Auto-dismisses at `event.startDate`.

### Known failures

- **F1 (R1).** Pulsing-dot affordance is absent. Mockup uses a
  red dot with rim-glow `bb-bob` animation — reads «active call»
  at a peripheral glance
- **F2 (R3).** No `Leave` button. User can dismiss the ribbon but
  must context-switch to Zoom to hang up. Mockup makes `Leave`
  the only filled-red CTA on the ribbon — the «end this thing»
  primary action
- **F3 (R4).** No `Mute` button. The call's mute control lives
  in another app's window; even a passive cross-app mute trigger
  would save the «cough scramble»
- **F4 (R5).** No `Agenda` button. Mockup adds a quiet ghost
  button that opens the agenda / linked docs in a sub-sheet
- **F5 (general).** The ribbon disappears at `event.startDate`
  but the meeting is still happening. Useful window is the
  meeting **body**, not the lead-time

## 3. Target design

- **Mockup**: `ui_kits/index2.html:2691–2714`

### Anatomy (target)

```
┌───────────────────────────────────────────────────────────────┐
│ ●  Sprint planning · in call               🎤   📄  ▣ Leave   │
│    06:42 elapsed · ends 14:45                                 │
└───────────────────────────────────────────────────────────────┘
```

### Key visual elements

- **Shell** — pill, 44 pt min-height, 999 px border-radius,
  `rgba(20, 22, 28, 0.78)` background with 40 pt blur saturate
  180 %, 0.5 pt white-12 % border, 20 / 50 pt 45 % drop-shadow.
  Floating above everything, draggable along the screen edge
- **Status dot** — 8 pt circle, `system-red`, with a 4 pt 26 %
  rim-glow box-shadow. Animated `bb-bob` (gentle pulse, 2 s
  duration, ease-in-out). Goes solid (no pulse) if mute is on
- **Title block** — two stacked lines:
  - Line 1: 12.5 pt 700 rounded, single-line ellipsis,
    `«<event title> · in call»`. The «in call» suffix replaces
    «Joined ·» (mockup convention; «Joined» is past-tense,
    «in call» is present-tense)
  - Line 2: 10.5 pt 500 mono, 55 % opacity, format
    `«MM:SS elapsed · ends HH:MM»`. Tabular nums
- **Spacer** — pushes the action group to the right edge
- **Action group** — three pill buttons:
  - `🎤 Mute` (ghost) — transparent background, 0.5 pt white-18 %
    border, 11.5 pt 600. Toggles to `🎤̸ Unmute` when muted;
    button background turns warm-red 18 % when active
  - `📄 Agenda` (ghost) — same style; opens the agenda sub-sheet
  - `▣ Leave` (filled red) — `system-red` (80 % black-mixed)
    background, 0 border, white text, 11.5 pt 700. The single
    primary on the ribbon

### Diff vs current

| | Current | Target |
|---|---------|--------|
| Status dot | none (checkmark icon instead) | pulsing red dot with rim-glow |
| Label | «Joined · Title» | «Title · in call» (present-tense) |
| Time line | lead-time countdown only | `elapsed` + `ends` while in-call |
| Mute | absent | ghost pill toggle |
| Agenda | absent | ghost pill, push to sub-sheet |
| Leave | absent | filled red primary |
| Re-alert | exists | removed — alert won't re-fire for the active call by definition |
| Lifecycle | dismisses at `event.startDate` | persists until `event.endDate`, OR user hits Leave / × |

## 4. Acceptance criteria

### Lifecycle

- [ ] Ribbon mounts on `Join` confirmation (existing path)
- [ ] Stays on screen until **`event.endDate`** OR user `Leave`
      OR `×` close. Today it dismisses at `event.startDate` —
      change to `endDate` so the in-call window is the useful
      one
- [ ] At `endDate`, the ribbon auto-fades with a 1 s gentle
      cross-fade (motion-aware)
- [ ] Drag-to-position along screen edges — the ribbon snaps to
      the nearest edge (top / bottom) and remembers position
      per-user

### Status dot

- [ ] Replace the leading checkmark icon with the 8 pt red dot +
      4 pt rim-glow + `bb-bob` pulse animation
- [ ] If `isMuted == true`, drop the pulse (solid dot) and apply
      a small `🎤̸` micro-glyph overlay in the dot's bottom-right
      corner

### Title block

- [ ] Line 1 reads `<title> · in call`
- [ ] Line 2: `«MM:SS elapsed · ends HH:MM»`. The «elapsed»
      counter ticks every second; «ends» is static

### Action buttons

- [ ] `Mute / Unmute` — uses macOS audio-input-mute API
      (`AudioObjectSetPropertyData` on
      `kAudioHardwareServiceDeviceProperty_VirtualMainMute`)
      or, where unavailable, a system-event AppleScript
      fallback for known apps. On failure, button shows a one-off
      toast «Couldn't reach the mic» and falls back to a
      «Bring conferencing app to front» action
- [ ] `Agenda` — pushes a sub-sheet (`AgendaPreviewView`) that
      renders `event.notes` (markdown) + linked docs. Same sheet
      used by the meeting-alert bottom strip
- [ ] `Leave` — first tries the conferencing app's URL scheme
      (`zoommtg://leave`, etc.); on unsupported, brings the app
      to front and lets the user hang up. Toast confirms what
      happened

### Visual

- [ ] Shell: 44 pt min-height, pill, glass material
      (`rgba(20,22,28,0.78)` + 40 pt blur). Same depth as the
      meeting alert window
- [ ] Always-on-top (`NSWindow.Level.floating`), but never
      `.screenSaver` — that level is reserved for the meeting
      alert
- [ ] Click-through on the dead zones (in `NSPanel`,
      `ignoresMouseEvents = true` on the transparent margin)

## 5. Out of scope

- **Cross-app camera toggle.** Mute is hard; camera-mute is
  harder (apps own their video pipelines). Skip
- **Volume controls on the ribbon.** macOS already provides
  these in the menu-bar; duplicating dilutes the ribbon's «in
  this call» frame
- **Multi-meeting ribbon.** What if two meetings overlap and the
  user joins the second mid-first? Current rule: latest-joined
  wins; previous ribbon implicitly hands over. Multi-stack is
  out of scope
- **Polished `AgendaPreviewView`.** First PR routes to a
  placeholder; see `meeting-alert.md` §5
- **Custom `Re-alert` button.** Removed in target. If the user
  dismissed the alert pre-join, they'll see the next stacked
  reminder fire normally; no re-alert button needed once the
  ribbon is present
- **Persistence of «have I joined?» across app restart.** If
  Bubo crashes mid-call, the ribbon won't come back on relaunch.
  Edge-case; defer
