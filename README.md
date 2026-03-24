<p align="center">
  <img src="screenshots/logo.png" alt="Bubo Logo" width="128">
</p>

<h1 align="center">Bubo</h1>

<p align="center">
  <em>A silent guardian in your menu bar.</em>
</p>

---

You're in the middle of writing the best code of your life. The flow state is real — ideas arrive faster than your fingers can type. Then a calendar notification punches through: *"Weekly Sync in 5 minutes."* You blink. You alt-tab. You open a bloated calendar app just to check if the meeting is actually important. By the time you return, the thought is gone. The flow is broken.

**This happens twelve times a day.**

<p align="center">
  <img src="screenshots/story_flow_broken.svg" alt="Flow state broken by notifications" width="700">
</p>

Bubo was built for people who are tired of this cycle. It's a native macOS menu bar app that quietly watches your schedule, blocks your focus time, and only interrupts you when it truly matters — like an eagle-owl perched above, seeing everything, disturbing nothing.

---

## The Moment You Click the Eagle-Owl

<img src="screenshots/ui_timeline.png" alt="Daily Timeline" width="300" align="right">

A frosted-glass panel drops down from your menu bar. No new window. No context switch. Just your day, laid out in a clean timeline — every meeting, every task, every block of time accounted for.

Bubo pulls from **iCloud, Google, Exchange, Outlook, and CalDAV** — all through the calendars you've already connected in macOS. No extra logins. No OAuth dance. If your Mac knows about a calendar, Bubo knows about it too.

The timeline shows what's next, how long until it starts, and who's attending. That's it. No noise. No clutter.

<br clear="both"/>

## Adding Something Takes Five Seconds

<img src="screenshots/ui_new_event.png" alt="Add Event Form" width="300" align="right">

Hit the **"+"** button. Type a name. Pick a time. Done.

Events sync back to Apple Calendar by default, or you can keep them completely local — invisible to the outside world. Private blocks of time that exist only between you and Bubo.

No heavy app to open. No loading spinner. Just a few keystrokes and you're back to work.

<br clear="both"/>

## Then There's The Pomodoro

<img src="screenshots/ui_pomodoro.png" alt="Pomodoro Session" width="300" align="right">

This is where Bubo becomes something different.

Toggle Pomodoro mode when creating an event, and Bubo locks you into a focus session. A ring timer appears. Your calendar blocks out. The world goes quiet.

When it's time to break, a full-screen alert rises — not a dismissible notification you'll ignore, but an unmissable signal that your brain needs rest.

<p align="center">
  <img src="screenshots/story_pomodoro.svg" alt="Pomodoro focus cycle" width="700">
</p>

Choose the rhythm that fits how you think:

| Rhythm | Work | Break | Rounds |
|---|---|---|---|
| **Classic** | 25 min | 5 min | 4 |
| **Deep Work** | 50 min | 10 min | 2 |
| **Sprinter** | 15 min | 3 min | 4 |
| **Ultradian** | 90 min | 20 min | 1 |

Read the full [Pomodoro & Workflow Guide →](docs/Pomodoro.md)

<br clear="both"/>

---

## You Will Not Miss a Meeting Again

It's 2 AM. You're deep in a vibe coding session — the AI is generating, you're reviewing, the terminal is hot. Three tabs of docs, a half-finished refactor, and a Spotify playlist that hasn't changed in four hours. You are *in it*.

And tomorrow at 9:00 you have a standup you've already missed twice.

With any other calendar app, that meeting would announce itself as a shy little banner in the top-right corner. You'd swipe it away without reading it, the way you've done a thousand times before. Or worse — you'd never see it at all, because notifications were silenced for "Focus Mode."

<p align="center">
  <img src="screenshots/story_vibe_coding.svg" alt="Without vs With Bubo comparison" width="700">
</p>

**Bubo doesn't do that.** When your meeting is approaching, the entire screen goes dark. A countdown timer fills your display — the meeting title, the time remaining, ticking down second by second. You cannot miss it. You cannot accidentally dismiss it. It is *there*, demanding exactly one decision: go to the meeting, or snooze.

This is the feature people didn't know they needed until they had it.

### Reminders You Actually Configure

<p align="center">
  <img src="screenshots/story_reminders.svg" alt="Stacking reminder intervals" width="650">
</p>

The beauty is in the setup. Open Settings, and you'll see a clean list of reminder intervals. Want to be nudged **30 minutes** before a big presentation, then again at **5 minutes**, then a final **1-minute** alert? Add all three. Want just a single 10-minute heads-up for daily standups? Done.

Stack as many intervals as you want — 1, 2, 3, 5, 10, 15, 20, 30, 45, 60 minutes — in any combination. Each event can even have its own custom overrides, so your "Lunch with Dad" gets a gentle 15-minute nudge while your "Board Review" gets the full 60 → 30 → 10 → 5 → 1 escalation sequence.

No confusing menus. No hidden preferences buried three screens deep. Just a list of times, and a toggle.

### Snooze Without Guilt

Not ready when the alert hits? Hit **Snooze** right from the full-screen overlay. Bubo steps back and comes again later. No judgment.

**Built like a Mac app should be.** Frosted glass. Spring animations. Haptic feedback. Bubo doesn't look like an Electron wrapper or a web view pretending to be native. It's Swift and SwiftUI from the first line to the last, designed to feel like it shipped with your Mac.

---

## Install

**One command:**
```bash
curl -fsSL https://raw.githubusercontent.com/avpv/bubo/HEAD/scripts/install.sh | bash
```

**Or download the DMG** from [Releases](https://github.com/avpv/bubo/releases/latest), drag to Applications, and run:
```bash
xattr -cr /Applications/Bubo.app
```

**Or build from source:**
```bash
git clone https://github.com/avpv/bubo.git
cd bubo
open -a Xcode Package.swift   # Cmd+R to run
```

Requires **macOS 13.0 Ventura** or later.

## Connect Your Calendars

1. **System Settings → Internet Accounts** — add your Google, Outlook, or Exchange accounts and enable Calendars.
2. Launch Bubo → **Settings** → **Calendars** → enable **Sync Apple Calendar Events**.
3. Grant the privacy permission when prompted.

That's it. Every calendar your Mac can see, Bubo can see.

---

<p align="center">
  <em>Bubo doesn't want your attention. It wants to protect it.</em>
</p>

<p align="center">
  <sub>Built with Swift & SwiftUI · MVVM Architecture · Zero dependencies</sub>
</p>
