import SwiftUI
import BuboOptimizer

// MARK: - Command Palette: Actions
//
// handleSubmit / runRequest pipeline + keyboard shortcuts wiring.
// Extracted from CommandPalette.swift.

extension CommandPalette {

    // MARK: - Actions

    func handleSubmit() {
        if let composed = composedRequest, showPowerMode {
            runRequest(composed)
        } else if !visibleItems.isEmpty {
            runRequest(visibleItems[min(selectedIndex, visibleItems.count - 1)].request)
        } else if !searchText.isEmpty {
            askAI(searchText)
        }
    }

    func runRequest(_ request: OptimizationRequest) {
        if IntentConflictDetector.hasErrors(request.intents) {
            conflicts = IntentConflictDetector.analyze(request.intents)
            showPowerMode = true
            composedRequest = request
            return
        }

        Haptics.tap()
        var working = request
        if let seedEvent { working = working.withEventContext(seedEvent) }
        lastExecutedRequest = request

        let label = working.findSlotOnly ? "Scheduling\u{2026}" : "Optimizing\u{2026}"
        phase = .working(label, intentName: working.name)

        workingTask?.cancel()
        workingTask = Task {
            let result = await optimizerService.executeRequest(working, reminderService: reminderService)
            if Task.isCancelled { return }
            await MainActor.run {
                workingTask = nil
                switch result {
                case .success, .partialSuccess:
                    guard !optimizerService.scenarios.isEmpty else {
                        phase = .failed(message: "No valid schedule found", resolutions: [])
                        return
                    }
                    optimizerService.applyScenario(at: 0, to: reminderService)
                    let fmt = DateFormatter()
                    fmt.setLocalizedDateFormatFromTemplate("H:mm")
                    let scenario = optimizerService.scenarios[0]
                    let infos = scenario.activeGenes.prefix(3).map { g in
                        EventInfo(id: g.eventId, title: g.title,
                                  timeRange: "\(fmt.string(from: g.startTime))–\(fmt.string(from: g.endTime))")
                    }
                    let resList: [ActionableResolution]
                    if case .partialSuccess(_, let warnings, let resolutions) = result {
                        appliedNotice = warnings.first
                        resList = resolutions
                    } else {
                        resList = []
                    }
                    phase = .applied(infos, resolutions: resList)
                    onApplied(request) { optimizerService.undoLast(reminderService: reminderService) }
                    Task { @MainActor in
                        if resList.isEmpty {
                            try? await Task.sleep(for: .seconds(3))
                            if case .applied = phase {
                                onDismiss()
                            }
                        }
                    }
                case .noEventsToOptimize:
                    phase = .failed(message: "Add tasks first", resolutions: [])
                case .infeasible(let reason, _, let resolutions):
                    phase = .failed(message: reason, resolutions: resolutions)
                }
            }
        }
    }

    func askAI(_ prompt: String) {
        guard agentService.isConfigured else {
            phase = .failed(message: "Add API key in Settings → Assistant", resolutions: [])
            return
        }
        Haptics.tap()
        phase = .working("Thinking\u{2026}", intentName: prompt)
        workingTask?.cancel()
        workingTask = Task {
            let result = await agentService.generateRequest(from: prompt)
            if Task.isCancelled { return }
            await MainActor.run {
                workingTask = nil
                switch result {
                case .success(let req): runRequest(req)
                case .failure(let err): phase = .failed(message: err.localizedDescription, resolutions: [])
                }
            }
        }
    }

    /// Narrow working hours to the hour boundaries of the seeded slot.
    func pinToSlot(_ request: inout OptimizationRequest) {
        guard let s = seedSlotStart, let e = seedSlotEnd else { return }
        let cal = Calendar.current
        let startHour = cal.component(.hour, from: s)
        let endHour = min(cal.component(.hour, from: e) + (cal.component(.minute, from: e) > 0 ? 1 : 0), 24)
        request.add(.workingHours(start: startHour, end: max(endHour, startHour + 1)))
    }

    func refreshPreview() {
        dryRunTask?.cancel()
        guard let top = visibleItems.first else { return }
        guard top.request.isCreative || top.request.findSlotOnly else { return }
        dryRunTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            var w = top.request; w.speed = .quick; w.maxScenarios = 1
            let genes = await optimizerService.executeDryRun(w, reminderService: reminderService)
            guard !Task.isCancelled else { return }
            if let genes, !genes.isEmpty {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                dryRunPreview = genes.prefix(2).map {
                    "\($0.title) \(fmt.string(from: $0.startTime))–\(fmt.string(from: $0.endTime))"
                }.joined(separator: " · ")
            }
        }
    }

    func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            // The keyboard glyph chip uses `DS.Typography.machineHint`
            // (the canonical voice for keyboard cues across the app —
            // see SmartActions calm-state ⌘K hint). Same font in both
            // surfaces means a user who learned the look in SmartActions
            // recognises it instantly here.
            Text(key)
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(RoundedRectangle(cornerRadius: DS.Spacing.xs).strokeBorder(skin.resolvedTextTertiary.opacity(DS.Opacity.softAccent), lineWidth: DS.Border.thin))
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    // MARK: - Keyboard

    @ViewBuilder
    var shortcuts: some View {
        Group {
            Button("Power mode") {
                withAnimation(DS.Animation.quick) {
                    if !showPowerMode, let top = visibleItems.first {
                        composedRequest = top.request
                    }
                    showPowerMode.toggle()
                }
            }
            .keyboardShortcut("e", modifiers: .option)
            Button("Close") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
