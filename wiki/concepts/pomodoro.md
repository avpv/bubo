# Pomodoro

> **Kind:** concept
> **Sources:** Bubo/Models/Domain/PomodoroDefaults.swift, Bubo/Models/Domain/ReminderSettings.swift, Bubo/Views/TimerScreenView.swift, Bubo/Services/PomodoroHistoryService.swift, Bubo/Optimizer/GACore/PomodoroSequenceChromosome.swift, Bubo/Optimizer/Intents/PomodoroConfigResolver.swift, Bubo/Optimizer/Fitness/Objectives/PomodoroFitObjective.swift, docs/Pomodoro.md
> **Last ingest:** 2026-05-11
> **Related:** [`../modules/optimizer.md`](../modules/optimizer.md), [`fitness-objectives.md`](fitness-objectives.md)

## The five rhythms

Defined in `Models/Domain/PomodoroDefaults.swift` as `PomodoroRhythm` (with `PomodoroPhase` for the work/break alternation):

| Rhythm | Work | Short break | Long break / cadence |
|---|---|---|---|
| Classic | 25 min | 5 min | 15 min after 4 cycles |
| Deep Work | 50 min | 10 min | longer block after 2–3 cycles |
| Sprinter | short, frequent | tight | sprinter-style cadence |
| 52/17 | 52 min | 17 min | (52/17 rule) |
| Ultradian | ~90 min | ~20 min | aligned with ultradian rhythm |

End-user docs and diagrams live in `docs/Pomodoro.md` and `docs/images/`.

## Where it touches the codebase

- **Settings:** `ReminderSettings.PomodoroDefaults` stores the user's chosen rhythm and overrides. `GeneralTabView` exposes the picker.
- **Events:** Pomodoro work blocks are `CalendarEvent`s with `EventType.pomodoro`. The optimizer can place them; users can also create them manually.
- **Optimizer encoding:** `PomodoroSequenceChromosome` (in `Optimizer/GACore/`) encodes a Pomodoro sequence specifically so crossover/mutation don't break the work-break invariant.
- **Optimizer objective:** `PomodoroFitObjective` (in `Optimizer/Fitness/Objectives/`) rewards schedules whose Pomodoro structure matches the active rhythm.
- **Rhythm resolution:** `PomodoroConfigResolver` (in `Optimizer/Intents/`) picks the right rhythm for a context (working hours, energy curve, intent overrides).
- **Timer UI:** `Views/TimerScreenView.swift` is the running-session view; `AppDelegate` owns the pinned window.
- **History:** `Services/PomodoroHistoryService.swift` persists session results for analytics and learning.

## Cross-cutting design notes

A Pomodoro block is not "just a meeting" — its objective in the schedule is different (focus protection vs attendance). The fitness function weights Pomodoro blocks against meetings via `FocusBlockObjective` and `ContextSwitchObjective` in addition to `PomodoroFitObjective`. See [`fitness-objectives.md`](fitness-objectives.md).
