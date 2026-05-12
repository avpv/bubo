# Pomodoro

> **Kind:** concept
> **Sources:** Sources/BuboDomain/Pomodoro/PomodoroDefaults.swift, Sources/BuboDomain/Calendar/CalendarEvent.swift, Sources/BuboDomain/Reminders/ReminderSettings.swift, Sources/BuboDomain/Recurrence/RecurrenceRule.swift, Bubo/Presentation/Views/Timer/TimerScreenView.swift, Bubo/Application/Pomodoro/PomodoroHistoryService.swift, Sources/BuboOptimizer/GeneticAlgorithm/PomodoroSequenceChromosome.swift, Bubo/Application/Intents/Rules/PomodoroConfigResolver.swift, Sources/BuboOptimizer/Fitness/Objectives/PomodoroFitObjective.swift, docs/Pomodoro.md
> **Last ingest:** 2026-05-12
> **Related:** [`../modules/optimizer.md`](../modules/optimizer.md), [`fitness-objectives.md`](fitness-objectives.md)

## Named rhythms (docs-only)

`docs/Pomodoro.md` describes five user-facing rhythm presets — Classic (25/5), Deep Work (50/10), Sprinter, 52/17, Ultradian (~90/20). **These are not Swift enum cases.** Grep `PomodoroRhythm` returns nothing — no type by that name exists. The rhythms are described in the docs and surface in UI pickers, but the code-level representation is the parameter tuple `(work, breakDur, rounds, longBreak)` carried by `PomodoroDefaults` and the recurrence rule.

If you came here looking for `enum PomodoroRhythm { case classic, deepWork, ... }` — it does not exist. The wiki used to claim it did; the claim was wrong.

## Code-level representation

| Type | File | Role |
|---|---|---|
| `struct PomodoroDefaults` (`:19`) | `Domain/PomodoroDefaults.swift` | **Smart-default generator** — given a target `durationMinutes`, suggests `(work, breakDur, rounds, longBreak)` using the 25/5 ratio, fitting as many full rounds as possible inside the window. Caps at 8 rounds. Used by "Convert to Pomodoro" so users don't open a form |
| `struct PomodoroPhase` (`:330`) | `Domain/Calendar/CalendarEvent.swift` | The work/break phase a running Pomodoro is *currently in*. `CalendarEvent.currentPomodoroPhase(at:)` (`:351`) derives the active phase given a wall-clock time |
| `RecurrenceRule.pomodoroMode: Bool` (`:12`), `pomodoroLongBreak: Int` (`:14`) | `Domain/Recurrence/RecurrenceRule.swift` | Flag on the recurrence rule so a recurring meeting can carry Pomodoro intent |
| `EventType.pomodoro` | `Domain/CalendarEvent.swift` | Marker on `CalendarEvent` distinguishing Pomodoro work blocks from regular meetings — feeds different objectives in the optimizer |

End-user docs and diagrams live in `docs/Pomodoro.md` and `docs/images/`.

## Where it touches the codebase

- **Settings:** `ReminderSettings` carries Pomodoro defaults. `GeneralTabView` exposes the picker.
- **Events:** Pomodoro work blocks are `CalendarEvent`s with `EventType.pomodoro`. The optimizer can place them; users can also create them manually.
- **Optimizer encoding:** `PomodoroSequenceChromosome` (in `Optimizer/GeneticAlgorithm/PomodoroSequenceChromosome.swift:12`) encodes a Pomodoro sequence specifically so crossover/mutation don't break the work-break invariant.
- **Optimizer objective:** `PomodoroFitObjective` (`Optimizer/Fitness/Objectives/`, weight 0.8) — uninterrupted-session fit + timing preference + post-session break adequacy (40/30/30 weights).
- **Rhythm resolution:** `PomodoroConfigResolver` (in `Application/Intents/`) picks the right rhythm for a context (working hours, energy curve, intent overrides).
- **Timer UI:** `Presentation/Views/TimerScreenView.swift` is the running-session view; `AppDelegate` owns the pinned window via `.pinTimerWindow` / `.unpinTimerWindow` notifications.
- **History:** `Application/PomodoroHistoryService.swift` persists session results — used by `PomodoroConfigResolver` to blend with the median of recent completed sessions at a similar time of day (`IntentCompiler.swift:32`).

## Cross-cutting design notes

A Pomodoro block is not "just a meeting" — its objective in the schedule is different (focus protection vs attendance). The fitness function weights Pomodoro blocks against meetings via `FocusBlockObjective` and `ContextSwitchObjective` in addition to `PomodoroFitObjective`. See [`fitness-objectives.md`](fitness-objectives.md).
