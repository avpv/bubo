<p align="center">
  <img src="docs/screenshots/logo.png" alt="Bubo" width="128">
</p>

<h1 align="center">Bubo</h1>

<p align="center">
  <strong>The planner that arranges your week for you — and lives in the menu bar.</strong><br>
  <sub>Native macOS app &middot; Requires macOS 13 Ventura or later</sub>
</p>

---

## What Bubo is now

A calendar tells you what's already on your schedule. **Bubo decides what should be.**

You hand Bubo a pile of meetings, deadlines, a backlog of tasks, and a few preferences ("deep work before lunch", "no calls Fridays", "ship X by Thursday"). Bubo runs a multi-objective genetic algorithm over your week and proposes an arrangement that respects every hard constraint and trades off the soft ones the way you've trained it to. One click to accept. One click to undo.

It still does everything the old Bubo did — full-screen meeting alerts, menu-bar timeline, Pomodoro, local-only events. Those are surfaces now. The engine underneath is new.

<p align="center">
  <img src="docs/screenshots/ui_timeline.png" alt="Bubo — daily timeline in the menu bar" width="380"><br>
  <sub>Your full day in the menu bar — one click, no app to launch</sub>
</p>

## The planner

### Tell it what you want, declaratively

Build a schedule from a picker of composable **intents** — Bubo's declarative DSL for steering the week. `block 2–5pm for deep work`, `prioritize project X`, `defer Y to Friday`, `cap to N events/day`, `cluster meetings`, `protect focus block`. They compose. Conflicts ("block 2–5pm" + "schedule X at 3pm") are flagged **before** the GA runs, not after.

A small catalog of named presets covers the common cases — "ship a feature", "interview week", "recovery day" — so you don't start from a blank screen.

### A real optimizer, not a "smart" sort

Under the menu bar is `BuboOptimizer` — an island-model genetic algorithm with adaptive operators, CP-SAT repair for infeasibility, and 16 fitness objectives running in parallel via NSGA-III many-objective selection. The objectives cover the things you'd ask a thoughtful assistant to weigh:

- **Conflict** and **precedence** (hard + soft pair — gross overlaps blocked, near-misses penalized)
- **Deadline pressure** with early-completion bonus and cramming penalty
- **Focus blocks** — longest uninterrupted span, fragmentation, average block length
- **Meeting clustering** — pack calls so the gaps are real
- **Context switching** — fuzzy-prefix project matching
- **Energy curve** — high-cost work at your peak hours, decay and recovery modelled
- **Week balance**, **day compactness**, **buffer between heavy meetings**, **Pomodoro fit**, **task placement**, **backlog ordering**, **break adequacy**, **multi-person availability**, **task inclusion**

You don't tune any of this directly. You accept or reject scenarios, and a DPO-style preference learner adjusts the objective weights to match your taste. Two users running Bubo on the same calendar will, after a few weeks, get different proposals.

### A backlog, not just a calendar

Tasks that don't have a fixed slot live in the **backlog** — recurring chores, projects in flight, things-to-do with a deadline but no specific time. The optimizer pulls from the backlog when it finds open space that fits the task's energy cost, dependencies, and preferred hours. Pin a backlog task to a day and the GA reflows the rest of the week around the pin.

### Shadow proposal

Alongside your live schedule Bubo keeps a **shadow proposal** — the GA's current best alternative. Accept it and the week reflows. Ignore it and it updates on the next change to your calendar or backlog.

## The focus surfaces (still here, still the point)

### Full-screen meeting alerts

The defining product feature. Five minutes before a call, **the entire screen goes dark** with a countdown and the meeting title. You physically cannot miss it. Stack multiple intervals — 30/10/1 min — so the alerts grow more urgent. Each event can override the defaults.

<p align="center">
  <img src="docs/screenshots/fullscreen_alert.gif" alt="Full-screen meeting alert in action" width="600"><br>
  <sub>Full-screen alert — you can't accidentally dismiss it</sub>
</p>

### Pomodoro mode

Toggle on any event and Bubo splits the slot into focused work sessions with timed breaks. A ring timer appears in the menu bar; the break is a full-screen overlay, not a notification you swipe away. Five named rhythms; the optimizer has a dedicated `PomodoroFitObjective` that protects sessions from being interrupted by surrounding events.

| Rhythm | Work | Break | Rounds |
|---|---|---|---|
| **Classic** | 25 min | 5 min | 4 |
| **Deep Work** | 50 min | 10 min | 2 |
| **Sprinter** | 15 min | 3 min | 4 |
| **52/17 Rule** | 52 min | 17 min | 3 |
| **Ultradian** | 90 min | 20 min | 1 |

Full [Pomodoro guide &rarr;](docs/Pomodoro.md)

### Menu-bar timeline

Click the owl, see the whole day in a frosted-glass panel, click away. No app launch, no window management. Reads every calendar your Mac knows: **iCloud, Google, Exchange, Outlook, CalDAV**. Connect once in System Settings; Bubo picks it up automatically.

### Local-only events

Block deep-work time without broadcasting it. Local-only events are stored only on your Mac, invisible to coworkers, and still factored into every GA run.

### Sync across Macs

User events, backlog tasks, per-event overrides, and reminder customizations sync via SwiftData + CloudKit. Last-write-wins per record. EventKit calendars sync via Apple's own machinery — Bubo doesn't double-handle them.

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

1. **System Settings &rarr; Internet Accounts** — add your Google, Outlook, or Exchange account and enable Calendars.
2. Launch Bubo &rarr; **Settings &rarr; Calendars** &rarr; enable **Sync Apple Calendar Events**.
3. Grant the privacy permission when prompted.

Every calendar your Mac can see, Bubo can see.

---

## Under the hood

Bubo is a single-process macOS app split into three SwiftPM targets — `BuboDomain` (value types, no deps), `BuboOptimizer` (the GA, constraints, fitness, learning), and `Bubo` (the AppKit/SwiftUI executable). Inside the app: Composition → Application → Infrastructure → Presentation. SwiftData for persistence, CloudKit for sync, EventKit for calendars, UserNotifications for alerts.

The full design notes — architecture, persistence, the event pipeline, every concept above written up with file:line references — live in the [wiki](wiki/index.md). Pages cite source so you can read the wiki and the code in parallel.

Highlights:

- [`wiki/architecture/overview.md`](wiki/architecture/overview.md) — composition root, observable services, three SwiftData containers
- [`wiki/concepts/genetic-algorithm.md`](wiki/concepts/genetic-algorithm.md) — chromosome, island model, adaptive bandits, MAP-Elites, CP-SAT repair
- [`wiki/concepts/fitness-objectives.md`](wiki/concepts/fitness-objectives.md) — all 16 objectives, weights, partitioning traits
- [`wiki/concepts/intents.md`](wiki/concepts/intents.md) — intent DSL, 8-stage compiler, learning
- [`wiki/concepts/constraints.md`](wiki/concepts/constraints.md) — hard constraints, Salsa-style memo caches, conflict graph
- [`wiki/concepts/full-screen-alerts.md`](wiki/concepts/full-screen-alerts.md) — pre-meeting takeover
- [`wiki/concepts/cloudkit-sync.md`](wiki/concepts/cloudkit-sync.md) — SwiftData + CloudKit, reconciliation, settings sync

---

<p align="center">
  <em>Bubo doesn't want your attention. It wants to plan your week so you keep it.</em>
</p>
