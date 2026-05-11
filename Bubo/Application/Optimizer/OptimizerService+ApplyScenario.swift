import Foundation

// MARK: - Apply Scenario
//
// Commit / reject paths for the scenarios produced by executeRequest.
// Extracted from OptimizerService.swift.

extension OptimizerService {

    // MARK: - Apply Scenario

    func applyScenario(
        at index: Int,
        to reminderService: ReminderService,
        titleOverride: String? = nil,
        colorOverride: EventColorTag? = nil
    ) {
        guard index < scenarios.count else { return }
        let scenario = scenarios[index]
        var createdEventIds: [String] = []
        let previousGenes = optimizer.currentSchedule

        optimizer.acceptScenario(scenario)

        // Remove old calendar events for tasks being rescheduled. Two
        // sources feed the removal set: direct id matches (the typical
        // case where the new gene reuses the old event id) and every
        // previously-scheduled chunk of each task being re-optimized.
        // The second source matters when a task changes shape between
        // runs — e.g., was a single event, is now split into `_p0`+`_p1`,
        // or vice versa — so we don't orphan the prior chunks.
        var idsToRemove = Set(scenario.activeGenes.map { $0.eventId })
        if let backlogService {
            let taskIds = Set(
                scenario.activeGenes.flatMap { gene -> [String] in
                    gene.reservedTaskIds.isEmpty
                        ? [gene.groupId ?? gene.eventId]
                        : gene.reservedTaskIds
                }
            )
            for taskId in taskIds {
                guard let task = backlogService.tasks.first(where: { $0.id == taskId }) else { continue }
                idsToRemove.formUnion(task.scheduledEventIds)
                if let primary = task.scheduledEventId { idsToRemove.insert(primary) }
            }
        }
        for id in idsToRemove {
            if reminderService.localEvents.contains(where: { $0.id == id }) {
                reminderService.removeLocalEvent(id: id)
            }
        }

        let cal = Calendar.current
        for (i, gene) in scenario.activeGenes.enumerated() {
            let title: String
            if let override = titleOverride, !override.isEmpty {
                title = scenario.activeGenes.count > 1 ? "\(override) \(i + 1)" : override
            } else {
                title = gene.title
            }

            // Post-GA shape refinement: the gene already has a config (picked
            // pre-GA with `currentHour`), but the slot it actually landed in
            // may sit hours from that assumption. Re-resolve the inner shape
            // with the real start hour, keeping the gene's duration as the
            // hard budget. Changes only work/break/rounds/longBreak —
            // `gene.endTime` stays intact.
            var pomodoroConfig = gene.pomodoroConfig
            if let originalConfig = gene.pomodoroConfig {
                let budget = max(
                    PomodoroResolverTuning.default.workBounds.lowerBound,
                    Int(gene.duration / 60)
                )
                var signals = PomodoroResolveSignals()
                signals.startHour = cal.component(.hour, from: gene.startTime)
                signals.learnedConfig = pomodoroHistory.learnedConfig(forHour: signals.startHour)
                    ?? originalConfig
                pomodoroConfig = PomodoroConfigResolver.resolveShape(
                    totalMinutes: budget,
                    startHour: signals.startHour,
                    signals: signals
                )
            }

            // Snapshot the backlog tasks bound to this gene so the timer
            // can show `taskSequence[round].title` and the backlog
            // service can link every consumed task to the same event.
            let sequence: [CalendarEvent.TaskSequenceEntry] = gene.reservedTaskIds.compactMap { id in
                guard let task = backlogService?.tasks.first(where: { $0.id == id }) else {
                    return nil
                }
                return CalendarEvent.TaskSequenceEntry(taskId: id, title: task.title)
            }

            var event = CalendarEvent(
                id: gene.eventId,
                title: title,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: "Created by Schedule Assistant",
                calendarName: nil,
                eventType: gene.isFocusBlock ? .pomodoro : .standard,
                colorTag: colorOverride ?? (gene.isFocusBlock ? .blue : .green)
            )
            event.pomodoroConfig = pomodoroConfig
            event.pomodoroTaskSequence = sequence
            reminderService.addLocalEvent(event)
            createdEventIds.append(event.id)
        }

        // Link backlog tasks to their scheduled events. Two shapes flow
        // through the same call:
        //   • Focus bursts: one gene carries N backlog tasks via
        //     `reservedTaskIds`. Each task points at the same pomodoro
        //     event.
        //   • Auto-chunked long tasks: N genes share a `groupId` equal
        //     to the parent backlog task id. The parent task links to
        //     every chunk's event id so unschedule/rescheduling can find
        //     them all. Plain backlog events fall through this same path
        //     as degenerate one-chunk groups.
        let focusGenes = scenario.activeGenes.filter { !$0.reservedTaskIds.isEmpty }
        let regularGenes = scenario.activeGenes.filter { $0.reservedTaskIds.isEmpty }

        for gene in focusGenes {
            for taskId in gene.reservedTaskIds {
                backlogService?.markScheduled(
                    id: taskId,
                    eventIds: [gene.eventId],
                    date: gene.startTime
                )
            }
        }

        let groupedByTask = Dictionary(grouping: regularGenes, by: { $0.groupId ?? $0.eventId })
        for (taskId, genes) in groupedByTask {
            let ordered = genes.sorted { $0.startTime < $1.startTime }
            let eventIds = ordered.map { $0.eventId }
            let earliest = ordered.first?.startTime ?? Date()
            backlogService?.markScheduled(
                id: taskId,
                eventIds: eventIds,
                date: earliest
            )
        }

        // Save undo snapshot
        lastSnapshot = AppliedSnapshot(
            requestName: activeRequestName ?? "",
            appliedAt: Date(),
            previousGenes: previousGenes,
            appliedGenes: scenario.activeGenes,
            createdEventIds: createdEventIds
        )

        // Record what was just applied for the «reasoning surface» (the
        // tiny "Done · why?" hint in `SmartActions`). The request's
        // intents drive the human-readable breakdown, the timestamp lets
        // the UI auto-fade after ~8 s. Mirrors `lastSnapshot` (used by
        // undo) but is purely advisory — no behaviour depends on it.
        if let request = activeRequest {
            lastAppliedRequest = AppliedRequestSummary(
                request: request,
                label: activeRequestName ?? request.name ?? "Optimization",
                appliedAt: Date(),
                taskCount: scenario.activeGenes.count,
                scenarioCount: scenarios.count,
                appliedScenarioIndex: index
            )
        }

        freshlyCreatedEventIds = Set(createdEventIds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            freshlyCreatedEventIds = []
        }

        selectedScenarioIndex = index

        // Record acceptance for intent learning
        if let request = activeRequest {
            intentLearner.recordExecution(request, outcome: .accepted)
        }
    }

    func rejectScenario(at index: Int) {
        guard index < scenarios.count else { return }
        optimizer.rejectScenario(scenarios[index])

        // Record rejection for intent learning
        if let request = activeRequest {
            intentLearner.recordExecution(request, outcome: .rejected)
        }
    }
}
