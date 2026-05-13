<p align="center">
  <img src="docs/screenshots/logo.png" alt="Bubo" width="128">
</p>

<h1 align="center">Bubo</h1>

<p align="center">
  <strong>The calendar that lives in your menu bar, protects your focus, and schedules your week for you.</strong><br>
  <sub>Native macOS app &middot; Requires macOS 13 Ventura or later</sub>
</p>

---

## What Bubo is

Bubo is a tiny owl in your menu bar that does three things at once:

1. **Shows your whole day** at a glance — one click, no app to launch.
2. **Makes meetings unmissable** — it takes over the screen before they start.
3. **Plans your week** — a multi-objective optimizer arranges meetings, tasks, focus blocks and Pomodoros so you don't have to.

Everything happens in the menu bar. There is no main window to manage, no dock icon stealing focus, no Electron tax. Just a 200&nbsp;MB native app that respects your attention.

<p align="center">
  <img src="docs/screenshots/ui_timeline.png" alt="Bubo — daily timeline in the menu bar" width="380"><br>
  <sub>Your full day in the menu bar — one click, no app to launch</sub>
</p>

---

## The two problems Bubo was built to fix

### "I keep missing meetings"

Most calendar apps send a small notification banner. You swipe it away out of habit. Bubo does something different: **the entire screen goes dark** with a countdown timer and meeting title. You physically cannot miss it.

<p align="center">
  <img src="docs/screenshots/fullscreen_alert.gif" alt="Full-screen meeting alert in action" width="600"><br>
  <sub>Full-screen alert — you can't accidentally dismiss it</sub>
</p>

Stack multiple reminder intervals — 30&nbsp;min, 10&nbsp;min, 1&nbsp;min — so alerts grow progressively more urgent. Each event can have its own set. Choose full-screen takeover, a native banner, or both.

<p align="center">
  <img src="docs/screenshots/custom_reminders.png" alt="Custom reminder intervals" width="300">
  &nbsp;&nbsp;
  <img src="docs/screenshots/settings_reminders.png" alt="Reminder settings" width="300"><br>
  <sub>Stack as many reminders as you want, from 1 to 120 minutes</sub>
</p>

After you click "Join", a slim **post-join ribbon** sits at the top of the screen with the current meeting title, remaining time, and a "join next" prompt if another call is right around the corner.

### "Checking my calendar breaks my flow"

Opening a calendar app means switching contexts. Bubo lives in the menu bar — click the owl, see your whole day in a frosted-glass panel, click away. The tiny **density bar** under the icon shows how full today already is, before you even open it.

It sees every calendar your Mac already knows: **iCloud, Google, Exchange, Outlook, CalDAV**. Connect an account in System Settings once — Bubo picks it up automatically. It can also pull and push **Apple Reminders** lists, so tasks and events live in one timeline.

---

## A scheduler, not just a viewer

Bubo isn't a read-only window onto your calendar. Press **⌃⇧⌘Space** anywhere in macOS and a small overlay appears.

<p align="center">
  <img src="docs/screenshots/quick_capture.png" alt="Global quick-capture hotkey" width="400"><br>
  <sub>⌃⇧⌘Space — capture a task without leaving your current app</sub>
</p>

Type a task, hit **↩** — it lands in your backlog. Hit **⇧↩** instead and Bubo opens the full editor pre-filled, so you can set a deadline, recurrence, priority, project or sub-tasks.

### The command palette

Click the wand or press **⌘K** to open Bubo's command palette. Type in plain English:

> _"Block 9 to 11 every weekday for deep work"_
> _"Defer everything tagged @writing to Friday"_
> _"Make sure I get an hour for lunch this week"_

The palette sends your request to **DeepSeek** (built-in free tier, no key required — or bring your own key) which translates it into a **schedule intent** — a typed, composable instruction. The intent is then handed to Bubo's optimizer.

Hold **⌥** to enter **power mode**: skip the AI and build the intent DAG yourself with conflict detection, suggestions, and reusable named sub-graphs.

### The optimizer

Behind the palette is a real multi-objective scheduler — an **island-model genetic algorithm** (`Sources/Optimizer/`) that arranges your week against 16 objectives in parallel:

| Soft objective | What it cares about |
|---|---|
| **Conflict** | No double-booking (paired with a hard constraint) |
| **Deadline** | Tasks finish before their deadline, without cramming |
| **Energy curve** | Heavy work at your personal peak hours |
| **Focus blocks** | Long uninterrupted stretches survive intact |
| **Meeting clustering** | Meetings cluster, focus time clusters — they don't shred each other |
| **Buffer** | Breathing room between heavy meetings |
| **Context switch** | Related work stays adjacent |
| **Pomodoro fit** | Work-break rhythms remain intact |
| **Break** | Lunch happens, breaks are real, not back-to-back marathons |
| **Day compactness** | Days don't sprawl |
| **Week balance** | Load spreads across the week |
| **Backlog order** | Higher-priority tasks come first |
| **Task placement** | Tasks land in their preferred hour windows |
| **Multi-person** | Group events placed when participants are likely available |
| **Precedence** | Dependent tasks finish before their successors |
| **Task inclusion** | Drop-able tasks get included whenever room exists |

The optimizer learns: per-workload bandits pick the best mutation operator, an attention head biases crossover toward the genes that matter, and a small GNN warm-starts the search from the conflict graph. Re-running on similar workloads is cheap.

Bubo shows a **shadow proposal** in the menu bar — the optimizer's best guess for your next move, one click to accept, undo always available.

---

## Pomodoro, properly integrated

Toggle **Pomodoro mode** on any event and Bubo splits it into focused work sessions with timed breaks. A ring timer appears in the menu bar; the optimizer treats Pomodoro blocks differently from meetings so they don't get shredded by context switches.

<p align="center">
  <img src="docs/screenshots/new_pomodoro.png" alt="Pomodoro session setup" width="300"><br>
  <sub>Visual work/break blocks — see your focus session before it starts</sub>
</p>

| Rhythm | Work | Break | Rounds |
|---|---|---|---|
| **Classic** | 25 min | 5 min | 4 |
| **Deep Work** | 50 min | 10 min | 2 |
| **Sprinter** | 15 min | 3 min | 4 |
| **52/17 Rule** | 52 min | 17 min | 3 |
| **Ultradian** | 90 min | 20 min | 1 |

When it's time to break, a full-screen overlay rises — not a notification you can swipe away, but a real signal to stop and rest. Each work block is also written to your calendar as a busy event, so colleagues see you protected.

Read the full [Pomodoro Guide &rarr;](docs/Pomodoro.md)

---

## Local-only events for private focus

Sometimes you need to block time without broadcasting it. Bubo lets you create **local-only events** — private time blocks stored only on your Mac (or synced via your own iCloud), invisible to anyone else.

<p align="center">
  <img src="docs/screenshots/new_event.png" alt="Quick event creation" width="300">
  &nbsp;&nbsp;
  <img src="docs/screenshots/local_only.png" alt="Local-only event" width="300"><br>
  <sub>"Event will be stored locally in Bubo only" — completely private</sub>
</p>

Create events in seconds: hit **+**, type a name, pick a time. Set up **recurring events** — daily, weekly on specific days, monthly ("second Tuesday"), yearly. Skip individual occurrences when plans change.

<p align="center">
  <img src="docs/screenshots/repeat_options.png" alt="Repeat options" width="300"><br>
  <sub>Flexible recurrence: daily, weekly, monthly, yearly</sub>
</p>

---

## Apple Reminders, two-way

Bubo treats Reminders lists as projects. Pick the lists you want — Bubo imports them into the backlog, the optimizer schedules them, and completed reminders sync back automatically. You can also push Bubo-only tasks out to a chosen Reminders list so they show up on iPhone.

<p align="center">
  <img src="docs/screenshots/reminders_sync.png" alt="Reminders sync" width="300"><br>
  <sub>Pick the lists you want, two-way sync, optional alarms</sub>
</p>

---

## Sync across your Macs

User-authored events, backlog tasks, per-event overrides and reminder customisations sync between your Macs through **CloudKit private database**. Settings (skin, wallpaper, intervals, badge mode) sync via `NSUbiquitousKeyValueStore`. Apple-Calendar events keep using Apple's own iCloud sync — Bubo doesn't duplicate them.

iCloud sync is fully optional. Flip it off and everything stays on the current Mac.

---

## Make it yours

### Skins

Skins are JSON-defined themes that change Bubo's mood — accent colour, button shape, badge style, font weight — without altering layout or semantic colours. A handful ship with the app; drop your own JSON into `~/Library/Application Support/Bubo/Presentation/Views/Skins/` and it appears in the picker.

### Wallpapers

Full-screen alerts pick from a catalog of built-in wallpapers, or you can supply your own photo with opacity and blur sliders.

### World clock

Pin up to a handful of cities to the menu-bar popover — useful if half your meetings are in another time zone.

<p align="center">
  <img src="docs/screenshots/settings_calendars.png" alt="Settings — Calendars" width="300">
  &nbsp;&nbsp;
  <img src="docs/screenshots/settings_general.png" alt="Settings — General" width="300"><br>
  <sub>One place for everything &middot; Launch at login &middot; Badge count &middot; Appearance</sub>
</p>

### Settings worth knowing about

- **Launch at login** — Bubo starts quietly with your Mac
- **Badge count** — pick what the menu-bar number means (unread reminders, today's events, next N hours, or off)
- **Reminder intervals** — stack as many as you want, from 1 to 120 minutes, per event or globally
- **Full-screen alerts or system notifications** — your choice
- **Light, Dark, or System** appearance
- **AI mode** — built-in (free, rate-limited) or your own DeepSeek key
- **Optimizer preferences** — working hours, buffer length, lunch window, energy curve

---

## Install

**With Homebrew:**
```bash
brew tap avpv/bubo https://github.com/avpv/bubo
brew install --cask bubo
```

**Or download the DMG** from [Releases](https://github.com/avpv/bubo/releases/latest), drag to Applications, and run:
```bash
xattr -cr /Applications/Bubo.app
```

**Or install from the command line:**
```bash
curl -fsSL https://raw.githubusercontent.com/avpv/bubo/HEAD/scripts/install.sh | bash
```

**Or build from source:**
```bash
git clone https://github.com/avpv/bubo.git && cd bubo
open -a Xcode Package.swift   # Cmd+R to run
```

## Connect your calendars

1. **System Settings &rarr; Internet Accounts** — add your Google, Outlook, or Exchange account and enable Calendars (and optionally Reminders).
2. Launch Bubo &rarr; **Settings &rarr; Calendars** &rarr; enable **Sync Apple Calendar Events**.
3. Grant the privacy permissions when prompted (Calendar, Reminders, Notifications, and Accessibility for the global hotkey).

Every calendar your Mac can see, Bubo can see.

---

## Under the hood

For the curious — Bubo is open source and a little unusual:

- **Three SwiftPM targets**: a pure-Foundation **`BuboDomain`** (value types only), a standalone **`BuboOptimizer`** (the multi-objective GA, no UI or services), and the macOS executable **`Bubo`**.
- **Composition root** wires every service once at launch; views read state from `@Observable` services, edge events fan out over `NotificationCenter`.
- **Three SwiftData containers** — an EventKit-derived cache (local-only), user-authored events (CloudKit), and the backlog (CloudKit). Reconciliation tolerates CloudKit's merge window.
- **Built-in DeepSeek proxy** (`proxy/`) — a small Cloudflare Worker handles rate limiting so users don't need an API key to try the AI features.

The full architecture wiki, kept in sync with the source by an LLM agent following the rules in [`AGENTS.md`](AGENTS.md), lives under [`wiki/`](wiki/).

---

<p align="center">
  <em>Bubo doesn't want your attention. It wants to protect it.</em>
</p>
