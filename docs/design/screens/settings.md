# Settings

> The infrequent-but-essential surface. Where calendar sources are
> hooked up, AI is keyed in, and the skin is picked. Opened once per
> setup change, never during daily flow — must be navigable cold.

## 1. JTBD

| #  | Когда | Хочу | Чтобы |
|----|-------|------|-------|
| S1 | Подключаю Bubo | Включить нужные календари | Видел свои события |
| S2 | Apple Reminders уже есть | Синхронизация задач | Не дублировать |
| S3 | Хочу AI-ассистента | Выбрать built-in или свой DeepSeek-ключ | Управлять стоимостью и приватностью |
| S4 | Не нравится дефолт-вид | Сменить скин | Bubo был мой |
| S5 | Какие сейчас лимиты у AI | Глянуть rate-limit | Понять, можно ещё или ждать |
| S6 | Нужен горячий клавишный жест | Глянуть/изменить shortcut | Не лезть в System Settings |

## 2. Current state

### Files

- **Shell** — `Bubo/Presentation/Views/Settings/SettingsView.swift:1–99`
- **General** — `Bubo/Presentation/Views/Settings/GeneralTabView.swift`
- **Appearance** — `Bubo/Presentation/Views/Settings/AppearanceTabView.swift:1–51`
- **Calendars** — `Bubo/Presentation/Views/Settings/CalendarsTabView.swift`
- **Apple Reminders** — `Bubo/Presentation/Views/Settings/AppleRemindersTabView.swift`
- **Notifications** — `Bubo/Presentation/Views/Settings/RemindersTabView.swift`
- **World Clock** — `Bubo/Presentation/Views/Settings/WorldClockTabView.swift`
- **Optimizer** — `Bubo/Presentation/Views/Settings/OptimizerTabView.swift`
- **Assistant (AI)** — `Bubo/Presentation/Views/Settings/AssistantTabView.swift:1–50+`

### Anatomy today

`SettingsView` is a split-pane window with an **8-tab sidebar**
(NavigationSplitView pattern). Tabs: General · Appearance ·
Calendars · Reminders (Apple) · Notifications · World Clock ·
Optimizer · Assistant.

Each tab is its own SwiftUI view with hand-rolled row layouts —
no shared `SettingsRow` primitive. AI tab differs notably:
mode-conditional sections (Built-in vs Own key), secure key
field, usage / privacy callouts, stale-task cleanup nudge.

### Known failures

- **F1 (S1, S2).** 8 tabs is a lot. Two of them are
  reminder-related (Apple Reminders + Notifications); two are
  scheduling-related (Optimizer + World Clock). Consolidating
  to **5 tabs** (Calendars · Reminders · AI · Appearance ·
  General) groups related concerns under one roof
- **F2 (row layout).** Each tab re-implements the row pattern.
  Adding a new toggle requires re-laying-out icon + label +
  hint + control. No shared primitive
- **F3 (S5).** AI rate-limit visualisation lives somewhere but
  is not the canonical «glance at how much AI you've used»
  surface. Mockup makes it a hero: 22 pt 700 «38 / 50» counter
  + 6 pt progress bar with green→accent gradient + «resets in
  4 h 12 m» on the right
- **F4 (S6).** Keyboard shortcuts (⌃⇧⌘␣ for Quick Capture,
  ⌘B for Backlog, ⌘K for Palette, etc.) aren't reviewable in
  one place. They live in various places (or only in code)

## 3. Target design

- **Mockup**:
  - `ui_kits/index2.html:2453–2506` (Calendars tab)
  - `ui_kits/index2.html:2508–2567` (AI tab — different layout)
  - `ui_kits/index2.html:2568–2614` (Appearance tab)

**Note on layout.** The mockup renders tabs as a top-horizontal
segmented control. We **diverge from the mockup here** and keep
the current `NavigationSplitView` sidebar: 5 entries (down from
8), but laid out vertically on the left. Rationale: macOS-native
Settings convention (System Settings, Mail, Calendar, every
recent Apple app), and the sidebar gives room to grow without
crowding tab labels. `PRINCIPLES.md §11` covers this: when HIG
(sidebar) and the mockup (top-tabs) disagree on a specific
decision, document the choice and move on.

### Anatomy (target)

```
┌──────────────────────────────────────────────────────┐
│                  Settings                          ✕ │ topbar
├──────────────┬───────────────────────────────────────┤
│ 📅 Calendars │ CALENDAR SOURCES                      │
│ 🔔 Reminders │ 🔵 iCloud · Work                  🟢  │ row
│ ✨ AI        │    42 events this week · synced 2 m   │
│ 🎨 Appearance│ 🔴 Google · me@example.com        🟢  │
│ ⚙ General   │    18 events · synced 5 min ago       │
│              │ 🟣 Exchange · team                ⚪  │
│              │    Disabled — re-auth in System Settings
│              │ 🟢 Bubo Local (private)           🟢  │
│              │    Stored on this Mac only            │
│              │                                       │
│              │ SYNC APPLE CALENDAR                   │
│              │ Read access                  🟢 ON    │
│              │    Granted — every calendar…          │
│              │                                       │
│              │ WORLD CLOCK                           │
│              │ Moscow · home · UTC · Belgrade · …  + │
├──────────────┴───────────────────────────────────────┤
│ Bubo · macOS 13+            v1.4.2 · Release notes   │ foot
└──────────────────────────────────────────────────────┘
```

### Tab structure (5 instead of 8)

| Target tab | Subsumes today | Notes |
|---|---|---|
| Calendars | Calendars · World Clock | World clock is calendar-scope; live nearby |
| Reminders | Reminders (Apple) · Notifications | Both about «when does Bubo poke you» |
| AI | Assistant | Renamed «AI» (lay term) |
| Appearance | Appearance | Unchanged |
| ⚙ General | General · Optimizer | Optimizer is power-user; folded into «advanced» |

### AI tab — hero rate-limit

```
MODE
○ Built-in (recommended)                       ●
  Bubo's hosted proxy. No key needed.
○ Own DeepSeek key
  Direct to api.deepseek.com. Stored in Keychain.

RATE LIMIT (built-in)
38 / 50                          resets in 4 h 12 m
▰▰▰▰▰▰▰▰▱▱▱▱  76 %                              ← green→accent gradient
When offline or rate-limited, the command palette
falls back to local intent presets.

API KEY (own mode)
DeepSeek key                              [Replace]
sk-···········9f2c — stored in macOS Keychain
```

### Appearance tab — skin grid

```
SKIN
┌──────────┐  ┌──────────┐
│ System   │  │ Coffee   │
│ macOS    │  │ Warm dark│
│       ✓  │  │          │
└──────────┘  └──────────┘
┌──────────┐  ┌──────────┐
│ Midnight │  │ Paper    │
│ Cool dark│  │ Light    │
└──────────┘  └──────────┘

WHAT SKINS CAN CHANGE
✓ Accent · button shape · weight
✓ Badge · separator style
✗ Spacing · sizing · materials
✗ Red/orange/green semantic meaning
```

## 4. Acceptance criteria

### Shell

- [ ] Keep the existing `NavigationSplitView` sidebar layout —
      do **not** switch to the mockup's top-horizontal tabs
      (HIG vs mockup conflict resolved in favour of HIG; see
      §3 «Note on layout»)
- [ ] Reduce sidebar entries from **8 to 5**:
      `📅 Calendars · 🔔 Reminders · ✨ AI · 🎨 Appearance ·
      ⚙ General`
- [ ] Sidebar entry styling stays platform-default
      (`Label(icon:title:)` rows). Selection state uses
      system accent — no custom chrome
- [ ] Topbar: `Settings` title 13 pt 700 + `✕` close on the
      right. Window chrome stays a separate macOS settings
      window (not a popover)

### Tab consolidation

- [ ] **Calendars** absorbs **World Clock** content as a second
      section below «Sync Apple Calendar». World-clock cities are
      a sub-section, not a top-level tab
- [ ] **Reminders** absorbs **Notifications**. First section is
      «Apple Reminders sync» (mode + list scope), second is
      «Bubo notifications» (which events alert, stacked
      reminder defaults, fullscreen-alert toggle)
- [ ] **General** absorbs **Optimizer**. Optimizer-specific
      settings (NSGA-III generations cap, fitness weights
      preset) live under an «Advanced» disclosure
- [ ] **AI** stays as its own tab (concerns: key, rate-limit,
      privacy). Rename `AssistantTabView` to `AITabView` for
      clarity

### Shared `SettingsRow`

- [ ] Same component as
      [`event-editor.md`](event-editor.md) §4. One row primitive,
      everywhere
- [ ] Variants:
      - `value` — trailing read-only mono text (e.g. «v1.4.2»)
      - `toggle` — trailing 32 × 18 capsule switch
      - `disclosure` — trailing chevron, pushes a sub-view
      - `picker` — trailing pill that opens a menu / sub-sheet
- [ ] Section header style: 10 pt 600 uppercase `fg-3` tracking
      `.06em`, 10 pt bottom-margin

### Calendars tab

- [ ] **Calendar sources** section:
      - One row per source: source-colour dot · name with hint
        («42 events this week · synced 2 min ago» or
        «Disabled — re-auth in System Settings») · toggle
      - Toggle off disables event ingest but keeps the source
        config (re-enabling is one tap)
      - Tap row body opens calendar list for that source
        (sub-sheet with per-calendar enable/disable)
- [ ] **Sync Apple Calendar** section: one row with
      `value`-style trailing — current EventKit permission
      state (`● ON` green / `● OFF` red), tap pushes a help
      sub-sheet if denied
- [ ] **World clock** section (subsumed): list of city chips +
      «Add city…» picker

### AI tab — hero rate-limit

- [ ] **Mode** section: two radio rows (Built-in / Own key),
      each with a 14 pt accent / hollow radio + lbl + hint
- [ ] **Rate limit (built-in)** section, visible only when mode
      is Built-in:
      - Big counter: «`38`» 22 pt 700 rounded tabular-nums +
        small «` / 50`» 13 pt 500 mono `fg-3`
      - Right-aligned: «`resets in 4 h 12 m`» 11 pt 500 mono `fg-3`
      - Progress bar: 6 pt height, 3 pt radius, fill = linear
        gradient `system-green → accent`
      - Caption: «When offline or rate-limited, the command
        palette falls back to local intent presets.» 11 pt 400
        `fg-3`
- [ ] **API key (own mode)** section, visible only when mode is
      Own key:
      - Row with masked key value (`sk-···········9f2c — stored
        in macOS Keychain`) and a `Replace` quiet chip
      - Tapping `Replace` opens a secure input sheet; new key
        validates against `api.deepseek.com` before saving

### Appearance tab — skin grid

- [ ] **Skin** section: 2-column `LazyVGrid`, 8 pt gap
- [ ] Each cell: 10 pt padding, 10 pt radius, gradient
      background using the skin's `previewColors`. Skin name +
      sub-line (one of «`Default · macOS native`», «`Warm dark ·
      rounded`», etc.) in skin-appropriate text colour
- [ ] Active skin: 2 pt accent border + white-on-accent check
      pill (16 pt circle) in top-right corner
- [ ] **What skins can change** info section: four bulleted
      lines (✓ accent · button shape · weight; ✓ badge ·
      separator style; ✗ spacing · sizing · materials;
      ✗ red/orange/green semantic meaning). Pulls from
      `PRINCIPLES.md §10`

### General tab

- [ ] **Appearance** sub-section: launch at login toggle ·
      menu-bar density bar toggle · world-clock visibility
- [ ] **Keyboard shortcuts** section: read-only list of all
      registered shortcuts (`⌘B Backlog`, `⌘K Palette`,
      `⌃⇧⌘␣ Quick Capture`, `⌘P Pomodoro`, `⌘I Intents`,
      `⌘, Settings`, `⌘Q Quit`). Each row has the
      `kbd-row` style. First PR: read-only; per-shortcut
      remapping is out of scope
- [ ] **Advanced** disclosure: optimizer presets (fitness
      weight bias, generations cap), telemetry opt-in, reset
      button

### Footer

- [ ] Two-column 11 pt 500 `fg-3` foot bar across all tabs:
      left «`Bubo · macOS 13+`», right «`v1.4.2 ·
      Release notes`» (link). Bottom border 0.5 pt; subtle
      `rgba(0,0,0,0.15)` background

## 5. Out of scope

- **Per-shortcut remapping UI.** Read-only first; remap UI
  later. Existing macOS conventions support copy-paste of
  shortcut into System Settings
- **Calendar account auth flows** (OAuth, CalDAV credentials).
  Those live in their own sheets behind the «Add calendar
  source» button; their refactor is a separate doc
- **Live preview of a skin change** (the popover behind the
  Settings reflects the skin in real time). Worth doing, but
  needs the skin engine to support hot-reload — defer
- **Telemetry dashboard.** A switch in Advanced is the v1
  surface; visualisation comes later
- **Export / import settings as a `.bubosettings` file.**
  Useful for moving between Macs; not in mockup; defer
- **Per-calendar custom colours.** Today the calendar's own
  colour drives Bubo's colour; overriding it is a Settings →
  Calendars sub-sheet job — defer
- **Apple Calendar / Reminders permission walk-through.** If
  permission is denied, the row should link to the System
  Settings panel. UX of that prompt is its own polish task
