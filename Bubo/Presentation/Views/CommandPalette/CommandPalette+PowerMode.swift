import SwiftUI

// MARK: - Command Palette: Power Mode
//
// Progressive-disclosure composer for OptimizationRequest tuning.
// Extracted from CommandPalette.swift.

extension CommandPalette {

    // MARK: - Power Mode (Progressive Disclosure)
    //
    // `@State` properties for the composer preview live on the main
    // `CommandPalette` struct (extensions cannot add stored properties).

    /// Advanced composer — only shown when user explicitly opts in.
    /// This is where the 65 intents live. But the user chose to see them.
    func powerModeComposer(_ request: OptimizationRequest) -> some View {
        // Read through the long-lived cache so SwiftUI body re-evaluations
        // (every chip toggle re-renders this view) hit a warm graph
        // instead of rebuilding 65-intent auto-resolution per keystroke.
        let graph = IntentGraphSalsaCache.shared.graph(for: request.intents)
        let phases = graph.intentsByPhase()
        let suggested = graph.suggestedIntents()

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Active intents grouped by phase
            ForEach(phases, id: \.phase) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.phase.displayName.uppercased())
                        // PRINCIPLES §8: section-label text uses the
                        // shared `DS.Typography.label(skin:)` voice
                        // (caption2, medium, active skin design) so
                        // every uppercase phase/section header in the
                        // app speaks the same Dynamic-Type-aware step.
                        .font(DS.Typography.label(skin: skin))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .tracking(0.5)

                    FlowLayout(spacing: DS.Spacing.xs) {
                        ForEach(group.intents) { node in
                            chip(
                                node.intent.label,
                                active: true,
                                dimmed: node.isAutoResolved
                            ) {
                                guard !node.isAutoResolved else { return }
                                var m = request
                                m.toggle(node.intent)
                                updateComposed(m)
                            }
                        }
                    }
                }
            }

            // Suggested
            if !suggested.isEmpty {
                FlowLayout(spacing: DS.Spacing.xs) {
                    ForEach(Array(suggested.prefix(6).enumerated()), id: \.offset) { _, intent in
                        chip(intent.label, active: false) {
                            var m = request
                            m.add(intent)
                            updateComposed(m)
                        }
                    }
                }
            }

            // Tunable parameters
            ForEach(Array(request.intents.enumerated()), id: \.offset) { idx, intent in
                parameterSlider(intent, at: idx, in: request)
            }

            // Conflicts
            if !conflicts.isEmpty {
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: conflict.severity == .error ? "xmark.circle.fill" : "info.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(conflict.severity == .error ? skin.resolvedDestructiveColor : skin.resolvedTextTertiary)
                            Text(conflict.message)
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                        
                        if !conflict.resolutions.isEmpty {
                            FlowLayout(spacing: DS.Spacing.xs) {
                                ForEach(conflict.resolutions) { res in
                                    Button(res.title) {
                                        var newReq = request
                                        newReq.merge(res.modifier)
                                        updateComposed(newReq)
                                    }
                                    .buttonStyle(.action(role: .secondary, size: .compact))
                                }
                            }
                            .padding(.leading, DS.Spacing.xl)
                        }
                    }
                }
            }

            // Preview
            if let preview = composerPreview {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "eye.fill")
                        .font(.footnote)
                        .foregroundStyle(skin.accentColor.opacity(DS.Opacity.overlayLight))
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(skin.accentColor.opacity(DS.Opacity.overlayDark))
                }
            }
        }
        .padding(DS.Spacing.sm)
        .onAppear { refreshComposerPreview(request) }
    }

    @ViewBuilder
    func parameterSlider(_ intent: ScheduleIntent, at idx: Int, in request: OptimizationRequest) -> some View {
        switch intent {
        case .focusBlock(let m, _):
            stepper("Focus", value: m, range: 30...240, step: 15, unit: "min") { v in
                var r = request; r.intents[idx] = .focusBlock(minutes: v); updateComposed(r)
            }
        case .noEventsBefore(let h):
            stepper("Start after", value: h, range: 6...14, step: 1, unit: ":00") { v in
                var r = request; r.intents[idx] = .noEventsBefore(hour: v); updateComposed(r)
            }
        case .noEventsAfter(let h):
            stepper("End by", value: h, range: 14...22, step: 1, unit: ":00") { v in
                var r = request; r.intents[idx] = .noEventsAfter(hour: v); updateComposed(r)
            }
        case .maxMeetings(let n):
            stepper("Max meetings", value: n, range: 0...10, step: 1, unit: "/day") { v in
                var r = request; r.intents[idx] = .maxMeetings(perDay: v); updateComposed(r)
            }
        default:
            EmptyView()
        }
    }

    func stepper(_ label: String, value: Int, range: ClosedRange<Int>, step: Int, unit: String, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .frame(width: 70, alignment: .leading)

            Button { onChange(max(range.lowerBound, value - step)) } label: {
                Image(systemName: "minus").font(.footnote.weight(.bold)).frame(width: 18, height: 18)
            }.buttonStyle(.plain)

            Text("\(value)\(unit)")
                .font(.footnote.monospacedDigit().weight(.medium))
                .frame(minWidth: 44)

            Button { onChange(min(range.upperBound, value + step)) } label: {
                Image(systemName: "plus").font(.footnote.weight(.bold)).frame(width: 18, height: 18)
            }.buttonStyle(.plain)

            Spacer()
        }
    }

    func updateComposed(_ request: OptimizationRequest) {
        composedRequest = request
        conflicts = IntentConflictDetector.analyze(request.intents)
        refreshComposerPreview(request)
    }

    func refreshComposerPreview(_ request: OptimizationRequest) {
        composerPreviewTask?.cancel()
        guard request.isCreative || request.findSlotOnly else {
            composerPreview = request.intents.prefix(3).map(\.label).joined(separator: " + ")
            return
        }
        composerPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            var w = request; w.speed = .quick; w.maxScenarios = 1
            let genes = await optimizerService.executeDryRun(w, reminderService: reminderService)
            guard !Task.isCancelled else { return }
            if let genes, !genes.isEmpty {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                composerPreview = genes.prefix(2).map {
                    "\($0.title) \(fmt.string(from: $0.startTime))–\(fmt.string(from: $0.endTime))"
                }.joined(separator: " · ")
            } else { composerPreview = "No slot found" }
        }
    }

    func chip(_ label: String, active: Bool, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if dimmed {
                    Image(systemName: "link").font(.system(size: 7, weight: .semibold))
                }
                Text(label).font(.footnote.weight(.medium))
                if active && !dimmed {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(dimmed ? skin.resolvedTextTertiary : active ? .white : skin.resolvedTextPrimary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                Capsule().fill(dimmed ? skin.accentColor.opacity(DS.Opacity.whisperFill) : active ? skin.accentColor : skin.accentColor.opacity(DS.Opacity.lightFill))
            )
        }
        .buttonStyle(.plain)
    }

}
