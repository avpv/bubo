<p align="center">
  <img src="screenshots/logo.png" alt="Bubo" width="128">
</p>

<h1 align="center">Bubo</h1>

<p align="center">
  <strong>Menu-bar calendar with a multi-objective planner for your week.</strong><br>
  <sub>Native macOS &middot; requires macOS 13 Ventura or later</sub>
</p>

---

Bubo lives in the menu bar, shows your day at a glance, and runs a genetic-algorithm planner over your meetings, deadlines, and backlog to propose how the week should be arranged.

## Install

Homebrew:

```bash
brew tap avpv/bubo https://github.com/avpv/bubo
brew install --cask bubo
```

From source:

```bash
git clone https://github.com/avpv/bubo.git && cd bubo
open -a Xcode Package.swift
```

Or grab a DMG from [Releases](https://github.com/avpv/bubo/releases/latest).

## Documentation

The canonical reference is the wiki — architecture, modules, and every planning concept written up with `file:line` citations into the source:

**[wiki/index.md](wiki/index.md)**

Start there for the GA, fitness objectives, intents, constraints, CloudKit sync, and the full-screen alert pipeline.
