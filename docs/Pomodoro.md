# Pomodoro Focus Timer

Bubo has a built-in Pomodoro timer that turns any event into a structured focus session. Toggle Pomodoro mode when creating or editing an event, and Bubo automatically generates work blocks, short breaks, and a long break — all visible on your timeline and blocked on your calendar.

<p align="center">
  <img src="../screenshots/ui_pomodoro.png" alt="Pomodoro session in Bubo" width="340">
</p>

## How it works

1. **Create an event** and enable Pomodoro mode.
2. **Pick a rhythm** (or keep the default Classic).
3. **Start working.** A ring timer counts down in the menu bar.
4. **Break when Bubo tells you.** A full-screen overlay appears — not a notification, but an unmissable signal to stop and rest.
5. **Repeat** until all rounds are complete, then take the long break.

Work sessions, breaks, and long breaks are each created as separate calendar events so your colleagues see you as busy during the entire block.

---

## Five rhythms

Bubo ships with five Pomodoro presets. Each one is designed for a different kind of work.

### Classic

The original Pomodoro recipe. Four short sprints with brief pauses — ideal for a mixed workload of tasks, reviews, and emails.

![Classic Pomodoro](images/classic-pomodoro-flowchart.svg)

| | |
|---|---|
| **Work** | 25 min |
| **Break** | 5 min |
| **Rounds** | 4 |
| **Long break** | 15 min |

Best for: everyday task lists, code reviews, email triage, writing.

---

### Deep Work

Longer sessions that let you load full context before the real progress begins. Use this when interruptions are destructive — architecture work, complex debugging, long-form writing.

![Deep Work](images/deep-work-flowchart.svg)

| | |
|---|---|
| **Work** | 50 min |
| **Break** | 10 min |
| **Rounds** | 2 |
| **Long break** | 20 min |

Best for: system design, refactoring, research, any task that needs 15+ minutes just to "load in."

---

### Sprinter

Ultra-short bursts that create urgency. The timer is so short you can't procrastinate — just pick one small thing and finish it before the bell.

![Sprinter](images/sprinter-flowchart.svg)

| | |
|---|---|
| **Work** | 15 min |
| **Break** | 3 min |
| **Rounds** | 4 |
| **Long break** | 15 min |

Best for: inbox zero, admin tasks, expense reports, quick fixes — anything small that keeps piling up.

---

### 52/17 Rule

Based on a study of the most productive workers: 52 minutes of focus followed by a 17-minute real break. The longer pause means you come back genuinely refreshed, not just paused.

![52/17 Rule](images/52-17-rule-flowchart.svg)

| | |
|---|---|
| **Work** | 52 min |
| **Break** | 17 min |
| **Rounds** | 3 |
| **Long break** | 30 min |

Best for: data work, strategic planning, coding sessions that need sustained attention without the intensity of Deep Work.

---

### Ultradian

One 90-minute block aligned with your body's natural alertness cycle. The most demanding rhythm — but nothing else matches it for the days when you need to go deep on a single problem.

![Ultradian](images/ultradian-90min-flowchart.svg)

| | |
|---|---|
| **Work** | 90 min |
| **Break** | 20 min |
| **Rounds** | 1 |

Best for: hard problems, creative work, presentations, anything that rewards unbroken concentration.

---

## Choosing a rhythm

| If your day looks like... | Try |
|---|---|
| A mix of small and medium tasks | **Classic** |
| One large, complex task | **Deep Work** |
| A pile of quick to-dos | **Sprinter** |
| Steady project work, nothing urgent | **52/17 Rule** |
| A single high-stakes deliverable | **Ultradian** |

You can change the rhythm for each event independently. There's no need to commit to one style for the whole day.

---

## Full-screen break alerts

When a work session ends, Bubo covers your screen with a break timer. This is intentional — the break is not optional. Research consistently shows that skipping breaks reduces performance across the remaining sessions. Bubo enforces the rhythm so you don't have to rely on willpower.

The alert disappears automatically when the break is over, or you can dismiss it early and return to the next work session.

---

## Tips

- **Name the task, not the time.** "Fix auth redirect" is better than "Pomodoro session." It keeps you accountable.
- **Pick the rhythm before you start.** Deciding mid-session wastes the focus you're trying to protect.
- **Honor the breaks.** Stand up. Look away from the screen. The timer is short — use every second of it.
- **Use local-only events** if you don't want Pomodoro blocks appearing on your shared calendar.
