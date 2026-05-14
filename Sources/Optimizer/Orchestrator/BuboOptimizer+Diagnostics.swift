import Foundation
import os
import BuboDomain

// MARK: - BuboOptimizer PlanWeek diagnostics
//
// Read via Console.app → subsystem `com.avpv.Bubo`, category `PlanWeek`.
// Both `OSLog` and `Logger` are kept: `Logger`'s typed interpolation is
// what we actually emit with, but `OSLog` lets us call `isEnabled(type:)`
// and skip the (very expensive — 50–200 line multi-line messages)
// diagnostic body when the level is filtered out. Without the early check,
// every PlanWeek invocation eagerly builds a multi-kilobyte string even
// when no one is listening.
//
// Extracted from `BuboOptimizer.swift` so the main file stays focused on
// the GA orchestration; this file owns the input/result narrative plus
// the static helpers (`anchorReplicationFraction`, `singleIslandConfig`,
// `weightsByObjectiveName`) used by the diagnostic path and a few
// dispatch-shaping sites in `BuboOptimizer.optimize(...)`.

private let planWeekOSLog = OSLog(subsystem: "com.avpv.Bubo", category: "PlanWeek")
private let planWeekLogger = Logger(planWeekOSLog)

public extension BuboOptimizer {

    // MARK: - PlanWeek Diagnostics Logging

    /// Log the consolidated input the GA is about to see: working
    /// window, busy fixed slots broken down by day, movable task list,
    /// and the adaptive GA budget picked for this workload. Intended
    /// for diagnosing "the optimizer is making odd choices" reports —
    /// a side-by-side of this and `logPlanWeekResult` tells you
    /// whether a surprising placement is an input problem (not enough
    /// room, conflicting deadline) or a solver problem (budget too
    /// small, bad fitness trade-off).
    func logPlanWeekInputs(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int>,
        horizon: DateInterval,
        prefs: OptimizerPreferences,
        gaCfg: GAConfiguration?,
        islandCfg: IslandConfiguration?
    ) {
        // Skip the whole diagnostic (kilobytes of string formatting) when
        // no one is listening at `.info`. The `GADebugLog.warn` anomaly
        // scan below is cheap and unconditional, so keep it outside the
        // gate.
        guard planWeekOSLog.isEnabled(type: .info) else {
            scanInputAnomalies(
                fixedEvents: fixedEvents.filter { horizon.intersects(DateInterval(start: $0.startDate, end: max($0.endDate, $0.startDate))) },
                movableEvents: movableEvents,
                horizon: horizon,
                workingHours: workingHours
            )
            return
        }

        let df = DateFormatter()
        df.dateFormat = "EEE dd.MM"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let cal = Calendar.current

        let fixedInWindow = fixedEvents.filter { horizon.intersects(DateInterval(start: $0.startDate, end: max($0.endDate, $0.startDate))) }
        let fixedHours = fixedInWindow.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 3600.0 }
        let movableHours = movableEvents.reduce(0.0) { $0 + $1.duration / 3600.0 }
        let workHoursPerDay = Double(workingHours.upperBound - workingHours.lowerBound)
        let difficulty = workloadDifficulty(movableEvents: movableEvents, fixedEvents: fixedEvents)

        var lines: [String] = []
        lines.append("=== PlanWeek inputs ===")
        lines.append(String(format: "horizon: %@ → %@ (%.1fh/day × window)",
                            df.string(from: horizon.start),
                            df.string(from: horizon.end),
                            workHoursPerDay))
        lines.append("working hours: \(workingHours.lowerBound):00-\(workingHours.upperBound):00")
        let peakHours = prefs.peakEnergyHours.sorted().map(String.init).joined(separator: ",")
        let curveSource = prefs.personalEnergyCurve != nil ? "personal" : "static"
        lines.append("peak energy: {\(peakHours)} (\(curveSource) curve)")
        let effectiveCompactness = prefs.dayCompactnessWeight ?? OptimizerPreferences.defaultDayCompactnessWeight
        lines.append(String(format: "weights: energy=%.2f placement=%.2f compactness=%.2f",
                            prefs.energyCurveWeight,
                            prefs.taskPlacementWeight,
                            effectiveCompactness))
        lines.append(String(format: "tasks: %d (%.1fh total), fixed: %d (%.1fh), difficulty: %.2f",
                            movableEvents.count, movableHours,
                            fixedInWindow.count, fixedHours,
                            difficulty))

        // Busy slots per day — the "consolidated slots" view: everything
        // already occupied that the GA must route around.
        lines.append("-- busy slots per day --")
        let fixedByDay = Dictionary(grouping: fixedInWindow) { cal.startOfDay(for: $0.startDate) }
        for day in fixedByDay.keys.sorted() {
            let dayEvents = fixedByDay[day]!.sorted { $0.startDate < $1.startDate }
            let busyH = dayEvents.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 3600.0 }
            let freeH = max(0, workHoursPerDay - busyH)
            var parts: [String] = []
            parts.append("\(df.string(from: day)): \(dayEvents.count) busy (\(String(format: "%.1f", busyH))h), ~\(String(format: "%.1f", freeH))h free")
            for ev in dayEvents.prefix(6) {
                parts.append("  \(tf.string(from: ev.startDate))-\(tf.string(from: ev.endDate)) \(ev.title)")
            }
            if dayEvents.count > 6 {
                parts.append("  … (+\(dayEvents.count - 6) more)")
            }
            lines.append(parts.joined(separator: "\n"))
        }

        lines.append("-- movable tasks --")
        for (i, ev) in movableEvents.enumerated() {
            var flags: [String] = []
            if ev.isFocusBlock { flags.append("focus") }
            if ev.isDroppable { flags.append("droppable") }
            if !ev.dependsOn.isEmpty { flags.append("deps=\(ev.dependsOn.count)") }
            if let gid = ev.groupId { flags.append("group=\(gid.prefix(6))") }
            if let pref = ev.preferredHourRange {
                flags.append("pref=\(pref.lowerBound)-\(pref.upperBound)")
            }
            let deadlineStr = ev.deadline.map { " deadline=\(df.string(from: $0))" } ?? ""
            let earliestStr = ev.earliestStart.map { " earliest=\(df.string(from: $0))" } ?? ""
            let ctx = ev.context.map { " ctx=\($0)" } ?? ""
            let spStr = ev.storyPoints.map { " sp=\($0)" } ?? ""
            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append(String(format: "  %2d. %.1fh p=%.2f e=%.2f%@%@%@%@%@ %@",
                                i + 1,
                                ev.duration / 3600.0,
                                ev.priority,
                                ev.energyCost,
                                spStr,
                                ctx,
                                deadlineStr,
                                earliestStr,
                                flagStr,
                                ev.title))
        }

        let gaDesc: String
        if let ga = gaCfg {
            gaDesc = "pop=\(ga.populationSize) maxGen=\(ga.maxGenerations) timeout=\(String(format: "%.1fs", ga.wallclockTimeout)) mut=\(String(format: "%.2f", ga.mutationRate)) xover=\(String(format: "%.2f", ga.crossoverRate))"
        } else {
            gaDesc = "instance default (pop=\(gaConfig.populationSize) maxGen=\(gaConfig.maxGenerations))"
        }
        let islandDesc: String
        if let ic = islandCfg {
            islandDesc = "islands=\(ic.islandCount) mig=\(ic.migrationInterval)/\(ic.migrationSize)"
        } else {
            islandDesc = "instance default (islands=\(islandConfig.islandCount))"
        }
        lines.append("GA budget: \(gaDesc) | \(islandDesc)")

        // Input anomaly scan. Flags things that usually indicate a
        // parsing / ingestion bug upstream — a malformed event that
        // makes it into the GA is going to produce a surprising
        // scenario, and filtering `GADebug` by `--level warning`
        // surfaces every hit alongside the invariant checks.
        scanInputAnomalies(
            fixedEvents: fixedInWindow,
            movableEvents: movableEvents,
            horizon: horizon,
            workingHours: workingHours
        )

        planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    /// Emit `GADebugLog.warn(site: "input", …)` lines for events that
    /// look malformed at ingest time. Non-blocking — the GA still
    /// runs — but every hit is something the caller probably wants
    /// to investigate.
    private func scanInputAnomalies(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>
    ) {
        // Movable-event anomalies.
        var eventIds: [String: Int] = [:]
        for event in movableEvents {
            eventIds[event.id, default: 0] += 1

            // Deadline before horizon start = guaranteed-infeasible
            // event. Either the deadline is wrong (stale task) or
            // the horizon is wrong.
            if let deadline = event.deadline, deadline < horizon.start {
                GADebugLog.warn(
                    site: "input",
                    message: "event deadline precedes horizon start",
                    context: [
                        "event": event.id,
                        "title": event.title,
                        "deadline": ISO8601DateFormatter().string(from: deadline),
                        "horizon_start": ISO8601DateFormatter().string(from: horizon.start)
                    ]
                )
            }

            // Deadline vs duration: if window is smaller than
            // duration, impossible to schedule legally.
            if let deadline = event.deadline,
               let earliest = event.earliestStart,
               deadline.timeIntervalSince(earliest) < event.duration {
                GADebugLog.warn(
                    site: "input",
                    message: "earliestStart..deadline window narrower than duration",
                    context: [
                        "event": event.id,
                        "window_sec": "\(Int(deadline.timeIntervalSince(earliest)))",
                        "duration_sec": "\(Int(event.duration))"
                    ]
                )
            }

            // Duration sanity. Zero / negative = parsing bug.
            // >12h = unusually long, possibly a `30m` parsed as hours.
            if event.duration <= 0 {
                GADebugLog.warn(
                    site: "input",
                    message: "non-positive duration",
                    context: ["event": event.id, "duration_sec": "\(Int(event.duration))"]
                )
            } else if event.duration > 12 * 3600 {
                GADebugLog.warn(
                    site: "input",
                    message: "unusually long duration (>12h) — possible parse error",
                    context: ["event": event.id, "hours": String(format: "%.1f", event.duration / 3600)]
                )
            } else if event.duration < 5 * 60 {
                GADebugLog.warn(
                    site: "input",
                    message: "unusually short duration (<5min) — possible parse error",
                    context: ["event": event.id, "minutes": String(format: "%.1f", event.duration / 60)]
                )
            }

            // Task duration longer than a whole working day — can
            // only fit if spanning the whole day, which fights most
            // soft objectives.
            let workdaySeconds = Double(workingHours.upperBound - workingHours.lowerBound) * 3600
            if event.duration > workdaySeconds {
                GADebugLog.warn(
                    site: "input",
                    message: "duration exceeds single working day",
                    context: [
                        "event": event.id,
                        "duration_h": String(format: "%.1f", event.duration / 3600),
                        "workday_h": String(format: "%.1f", workdaySeconds / 3600)
                    ]
                )
            }
        }

        // Duplicate ids.
        for (id, count) in eventIds where count > 1 {
            GADebugLog.warn(
                site: "input",
                message: "duplicate movable event id",
                context: ["event": id, "count": "\(count)"]
            )
        }

        // Fixed-event anomalies.
        for event in fixedEvents {
            if event.endDate <= event.startDate {
                GADebugLog.warn(
                    site: "input",
                    message: "fixed event has non-positive duration",
                    context: [
                        "event": event.id,
                        "start": ISO8601DateFormatter().string(from: event.startDate),
                        "end": ISO8601DateFormatter().string(from: event.endDate)
                    ]
                )
            }
        }
    }

    /// Log what the GA returned: per-scenario placements grouped by
    /// day, dropped tasks, fitness with top objective breakdown, and
    /// solver metadata (generations, convergence, wall time). Pair
    /// with `logPlanWeekInputs` to see whether the final schedule
    /// lines up with the inputs and constraints.
    func logPlanWeekResult(
        result: OptimizerResult,
        movableEvents: [OptimizableEvent],
        wallDuration: TimeInterval,
        context: OptimizerContext,
        telemetry: FitnessEvalTelemetry.Snapshot
    ) {
        // Early-exit when `.info` is disabled — the body below formats a
        // multi-kilobyte per-scenario report that's pure wasted work if
        // no one is listening.
        guard planWeekOSLog.isEnabled(type: .info) else { return }

        let df = DateFormatter()
        df.dateFormat = "EEE dd.MM"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let cal = Calendar.current
        let titleById = Dictionary(uniqueKeysWithValues: movableEvents.map { ($0.id, $0.title) })

        var lines: [String] = []
        lines.append("=== PlanWeek result ===")
        let meta = result.metadata
        lines.append(String(format: "scenarios=%d, wall=%.2fs (GA=%.2fs), gen=%d, convergedAt=%d, bestFit=%.4f, avgFit=%.4f",
                            result.scenarios.count,
                            wallDuration,
                            meta.totalDuration,
                            meta.generations,
                            meta.convergenceGeneration,
                            meta.bestFitness,
                            meta.averageFitness))

        if result.scenarios.isEmpty {
            lines.append("(no scenarios produced — GA returned empty population)")
            planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
            return
        }

        for (idx, scenario) in result.scenarios.enumerated() {
            lines.append("-- scenario #\(idx + 1) --")
            let active = scenario.activeGenes
            let dropped = scenario.genes.filter { !$0.isIncluded }
            lines.append(String(format: "fitness=%.4f, placed=%d, dropped=%d, violations=%d",
                                scenario.fitness,
                                active.count,
                                dropped.count,
                                scenario.constraintViolations.count))

            // Top objectives (most-negative first — those hurt fitness
            // the most and usually explain surprising trade-offs).
            let topObjectives = scenario.objectiveBreakdown
                .sorted { $0.value < $1.value }
                .prefix(5)
            if !topObjectives.isEmpty {
                let objStr = topObjectives
                    .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
                    .joined(separator: ", ")
                lines.append("top objectives: \(objStr)")
            }

            // Weighted-contribution view: raw × weight × (1 - raw)
            // reveals which objectives are *actually* eating the
            // fitness budget, which the raw-score ordering alone
            // can miss — a low-weight objective with score 0.2
            // contributes less than a high-weight objective at
            // score 0.8. Sorted by contribution-to-loss desc so
            // the first line is "this is where your fitness went".
            let weightsByName = weightsByObjectiveName(context.preferences)
            let contributions: [(name: String, raw: Double, weight: Double, lossPct: Double)] =
                scenario.objectiveBreakdown.compactMap { entry in
                    guard let weight = weightsByName[entry.key], weight > 0 else { return nil }
                    return (entry.key, entry.value, weight, weight * (1 - entry.value))
                }
            let totalLoss = contributions.reduce(0.0) { $0 + $1.lossPct }
            if totalLoss > 0 {
                let ranked = contributions
                    .sorted { $0.lossPct > $1.lossPct }
                    .prefix(5)
                let parts = ranked.map { entry -> String in
                    let pct = Int((entry.lossPct / totalLoss * 100).rounded())
                    return "\(entry.name)=\(pct)%"
                }
                lines.append("fitness loss by: \(parts.joined(separator: ", "))")
            }

            if !scenario.constraintViolations.isEmpty {
                let shown = scenario.constraintViolations.prefix(5).joined(separator: "; ")
                let suffix = scenario.constraintViolations.count > 5
                    ? " (+\(scenario.constraintViolations.count - 5) more)" : ""
                lines.append("violations: \(shown)\(suffix)")
            }

            // Placements grouped by day — the "how the optimizer
            // laid tasks into slots" view the user asked for.
            let byDay = Dictionary(grouping: active) { cal.startOfDay(for: $0.startTime) }
            for day in byDay.keys.sorted() {
                let genes = byDay[day]!.sorted { $0.startTime < $1.startTime }
                let dayHours = genes.reduce(0.0) { $0 + $1.duration / 3600.0 }
                lines.append("  \(df.string(from: day)) — \(genes.count)\u{00A0}tasks, \(String(format: "%.1f", dayHours))\u{00A0}h:")
                for g in genes {
                    let title = titleById[g.eventId] ?? g.title
                    let mins = Int((g.duration / 60).rounded())
                    let spStr = g.storyPoints.map { " sp=\($0)" } ?? ""
                    lines.append(String(format: "    %@-%@ (%dm) p=%.2f%@ %@",
                                        tf.string(from: g.startTime),
                                        tf.string(from: g.endTime),
                                        mins,
                                        g.priority,
                                        spStr,
                                        title))
                }
            }

            if !dropped.isEmpty {
                let entries = dropped.prefix(8).map { g -> String in
                    let title = titleById[g.eventId] ?? g.title
                    let mins = Int((g.duration / 60).rounded())
                    let spStr = g.storyPoints.map { " sp=\($0)" } ?? ""
                    return String(format: "%@ (p=%.2f%@ %dm)", title, g.priority, spStr, mins)
                }
                let suffix = dropped.count > 8 ? " (+\(dropped.count - 8) more)" : ""
                lines.append("  dropped: \(entries.joined(separator: ", "))\(suffix)")
            }
        }

        // Cross-scenario: which tasks never got placed by any scenario?
        // A task that's always dropped usually means the inputs can't
        // fit it, not that the GA missed an option.
        let everPlaced = Set(result.scenarios.flatMap { $0.activeGenes.map(\.eventId) })
        let neverPlaced = movableEvents.filter { !everPlaced.contains($0.id) }
        if !neverPlaced.isEmpty {
            let entries = neverPlaced.prefix(8).map { ev -> String in
                let mins = Int((ev.duration / 60).rounded())
                let spStr = ev.storyPoints.map { " sp=\($0)" } ?? ""
                return String(format: "%@ (p=%.2f%@ %dm)", ev.title, ev.priority, spStr, mins)
            }
            let suffix = neverPlaced.count > 8 ? " (+\(neverPlaced.count - 8) more)" : ""
            lines.append("never placed across any scenario: \(entries.joined(separator: ", "))\(suffix)")
        }

        // Mutation bandit arm usage: pulls and mean clipped reward per
        // operator. Lets a diagnostician see at a glance whether one
        // arm (usually `shift`) dominated and starved the others, or
        // whether the bandit actually tried every operator.
        let banditSnap = context.mutationBandit.snapshot
        let totalPulls = banditSnap.values.reduce(0) { $0 + $1.pulls }
        if totalPulls > 0 {
            let order: [MutationOperator] = [.shift, .moveDay, .snap, .guided, .lnsDay]
            let parts: [String] = order.compactMap { op in
                guard let t = banditSnap[op], t.pulls > 0 else { return nil }
                let name: String
                switch op {
                case .shift:   name = "shift"
                case .moveDay: name = "moveDay"
                case .snap:    name = "snap"
                case .guided:  name = "guided"
                case .lnsDay:  name = "lnsDay"
                }
                return "\(name)=\(t.pulls)(r=\(String(format: "%.3f", t.meanReward)))"
            }
            if !parts.isEmpty {
                lines.append("mutation bandit: \(parts.joined(separator: ", "))")
            }
        }

        // Working-day set + horizon breakdown so a surprising
        // placement can be root-caused to "the configured working
        // days don't match expectations" or "Monday is a public
        // holiday in the calendar but not to the solver".
        let cal2 = context.calendar
        let prefs = context.preferences
        let workingDays = prefs.workingDays
        let horizonStartDay = cal2.startOfDay(for: context.planningHorizon.start)
        let horizonLastDay = cal2.startOfDay(for: context.planningHorizon.end.addingTimeInterval(-1))
        let horizonDays = max(1, (cal2.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)
        var workDays = 0
        for offset in 0..<horizonDays {
            guard let day = cal2.date(byAdding: .day, value: offset, to: horizonStartDay) else { continue }
            if !prefs.isWorkingDay(day, calendar: cal2) { continue }
            workDays += 1
        }
        // Weekday abbreviations in sorted 1→7 order (Sun, Mon, …, Sat).
        let weekdayAbbrev = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let daysLabel = workingDays.sorted().compactMap { idx -> String? in
            guard idx >= 1, idx <= 7 else { return nil }
            return weekdayAbbrev[idx - 1]
        }.joined(separator: ",")
        lines.append("flags: workingDays=[\(daysLabel)], workDaysInHorizon=\(workDays)/\(horizonDays)")

        // Slot-registry footprint: total valid slots in the discrete
        // search space the GA operated on. Orders-of-magnitude smaller
        // than the continuous Date range, which is the whole point of
        // the slot-based decoder — see the "Slot-Based Decoder"
        // MARK in Chromosome.swift. Stride is auto-detected by
        // `SlotRegistry.autoDetectStride` — 15-min when the workload
        // is aligned, 5-min when a fixed event / movable duration
        // introduces off-quarter minutes.
        let slotRegistry = context.ensureSlotRegistry()
        let strideMinutes = Int((slotRegistry.stride / 60).rounded())
        lines.append("slots: registry=\(slotRegistry.count), stride=\(strideMinutes)\u{00A0}min")

        // Fitness evaluator telemetry — δ-eval hit rate + constraint
        // rejection count. A δ-hit rate below ~50% flags that recent
        // mutations aren't getting the partitioned-objective speedup
        // (usually because mutations affect many days or the mutated
        // hint is missing). A rising `constraintRejections` count
        // means many chromosomes fail `ConstraintEngine.isValid` and
        // are getting the infeasible gradient scaling — fine during
        // early generations, symptomatic late.
        let total = telemetry.total
        if total > 0 {
            let deltaPct = Int((telemetry.deltaFraction * 100).rounded())
            let cachePct = Int((telemetry.cacheHitFraction * 100).rounded())
            lines.append(String(
                format: "fitness evals: total=%d full=%d delta=%d(%d%%) cache=%d(%d%%) rejections=%d",
                total,
                telemetry.fullEvaluations,
                telemetry.deltaEvaluations, deltaPct,
                telemetry.cacheHits, cachePct,
                telemetry.constraintRejections
            ))
        }

        // Slot-binding coverage on the best scenario: how many genes
        // actually carry a registry-bound `slotIndex`. A coverage
        // number below 1.0 flags genes that slipped through a
        // producer that still uses `withStartTime` — useful for
        // spotting reoptimizer/warm-start regressions after the
        // slot-decoder migration.
        if let best = result.scenarios.first {
            let active = best.activeGenes
            if !active.isEmpty {
                let bound = active.filter { $0.slotIndex != nil }.count
                let coverage = Double(bound) / Double(active.count)
                lines.append(String(format: "slots: coverage=%.2f (%d/%d active genes slot-bound)",
                                    coverage, bound, active.count))
            }
        }

        // Constraint breakdown on the best scenario. Lets a
        // diagnostician see at a glance *which* constraint(s) are
        // eating fitness — e.g. a dominant `Buffer` penalty hints at
        // too-tight back-to-back placements, while a dominant
        // `MaxMeetingsPerDay` penalty hints at a cap the user should
        // raise. Prints the top-5 penalising constraints (soft or
        // hard) with their raw penalty magnitude.
        if let best = result.scenarios.first {
            let scenarioChromosome = ScheduleChromosome(
                genes: best.genes,
                needsEvaluation: false
            )
            let engine = ConstraintEngine.standard
            let breakdown = engine.breakdown(for: scenarioChromosome, context: context)
                .filter { $0.penalty > 0 }
                .sorted { $0.penalty > $1.penalty }
                .prefix(5)
            if !breakdown.isEmpty {
                let parts = breakdown.map { entry -> String in
                    let kind = entry.isHard ? "H" : "S"
                    return "\(entry.name)[\(kind)]=\(String(format: "%.1f", entry.penalty))"
                }
                lines.append("constraints: \(parts.joined(separator: ", "))")
            }
        }

        planWeekLogger.info("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    /// Map `FitnessObjective.name` → weight from the current
    /// preferences. Used by the weighted-contribution diagnostic
    /// in the result log. Names must match the `FitnessObjective.name`
    /// strings at each objective's call site in
    /// `Sources/Optimizer/Fitness/Objectives/`.
    private func weightsByObjectiveName(_ prefs: OptimizerPreferences) -> [String: Double] {
        return [
            "FocusBlock":         prefs.focusBlockWeight,
            "PomodoroFit":        prefs.pomodoroFitWeight,
            "Conflict":           prefs.conflictWeight,
            "TaskPlacement":      prefs.taskPlacementWeight,
            "WeekBalance":        prefs.weekBalanceWeight,
            "EnergyBalance":      prefs.energyCurveWeight,
            "MultiPerson":        prefs.multiPersonWeight,
            "BreakPlacement":     prefs.breakWeight,
            "Deadline":           prefs.deadlineWeight,
            "ContextSwitch":      prefs.contextSwitchWeight,
            "Buffer":             prefs.bufferWeight,
            "MeetingClustering":  prefs.meetingClusteringWeight,
            "TaskInclusion":      prefs.taskInclusionWeight,
            "BacklogOrder":       prefs.backlogOrderWeight ?? OptimizerPreferences.defaultBacklogOrderWeight,
            "DayCompactness":     prefs.dayCompactnessWeight ?? OptimizerPreferences.defaultDayCompactnessWeight
        ]
    }

    /// Workloads below this difficulty scalar get their GA budget
    /// capped in `optimize` even when the caller supplied a heavier
    /// `overrideConfig`. A 4-task week with no conflicts scores
    /// around 0.18 via `workloadDifficulty`; the 0.25 threshold lets
    /// that case and similar-sized backlogs escape the `.thorough`
    /// budget without forcing the downshift on mid-sized weeks that
    /// genuinely benefit from more generations.
    static let trivialWorkloadDifficulty: Double = 0.25

    /// Lower bound returned by `workloadDifficulty` for an
    /// almost-empty schedule. Anchors the high end of the
    /// adaptive-weight boost so a 1-task no-meeting day yields
    /// `boost ≈ 1.0`.
    static let workloadDifficultyFloor: Double = 0.05

    /// Upper bound on difficulty where `.refine` is still the right
    /// GA config when CP-SAT delivered an anchor. Above this the
    /// workload has genuine exploration need even with a good start
    /// — fall through to the caller's configured preset so the
    /// heavier machinery (multi-island, memetic hill climb,
    /// adaptive mutation) gets a chance to fire.
    static let mediumWorkloadDifficulty: Double = 0.6

    /// Fraction of each island's initial population seeded as
    /// mutated copies of the CP-SAT anchor, chosen by dispatch mode.
    /// Higher in `polish` (tight cloud around the lex-optimum,
    /// minimal exploration) and lower in `seeded_full` (anchor is
    /// one hint among many, GA still needs room to search).
    static func anchorReplicationFraction(forMode mode: String) -> Double {
        switch mode {
        case "polish":      return 0.6
        case "refine":      return 0.4
        case "seeded_full": return 0.2
        default:            return 0.0
        }
    }

    /// Collapse the supplied island configuration to a single-island
    /// variant, preserving migration and replacement policies so any
    /// downstream code that reads them stays happy. Used by the
    /// polish / refine dispatch because multi-island only pays off
    /// when the populations per island are large enough for
    /// migration to meaningfully diversify — not the case here.
    static func singleIslandConfig(from source: IslandConfiguration) -> IslandConfiguration {
        guard source.islandCount > 1 else { return source }
        return IslandConfiguration(
            islandCount: 1,
            migrationInterval: source.migrationInterval,
            migrationSize: source.migrationSize,
            topology: source.topology,
            emigrantSelection: source.emigrantSelection,
            immigrantReplacement: source.immigrantReplacement,
            diversifyIslands: false,
            adaptiveMigration: false,
            routeByProductivity: false
        )
    }

}
