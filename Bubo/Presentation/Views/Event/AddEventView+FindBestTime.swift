import SwiftUI

// MARK: - AddEventView: Find Best Time
//
// Optimizer-driven slot suggestion section + helpers.
// Extracted from AddEventView.swift.

extension AddEventView {

    // MARK: - Find Best Time

    func findBestTimeSection(_ service: OptimizerService) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Button {
                Haptics.tap()
                findBestTime(service)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    if isFindingBestTime {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.footnote)
                    }
                    Text("Find Best Time")
                        .font(.footnote.weight(.regular))
                }
                .foregroundStyle(skin.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isFindingBestTime)

            if !bestTimeSlots.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(bestTimeSlots.prefix(3).enumerated()), id: \.offset) { index, scenario in
                        if let gene = scenario.genes.first {
                            Button {
                                Haptics.tap()
                                date = gene.startTime
                                bestTimeSlots = []
                            } label: {
                                HStack(spacing: DS.Spacing.sm) {
                                    if index == 0 {
                                        Image(systemName: "star.fill")
                                            .font(.footnote)
                                            .foregroundStyle(skin.accentColor)
                                    }
                                    Text(DS.timeFormatter.string(from: gene.startTime))
                                        .font(.footnote.weight(.regular).monospacedDigit())
                                        .foregroundStyle(skin.resolvedTextPrimary)
                                    Text("(\(Int(scenario.fitness * 100))%)")
                                        .font(.footnote)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                    Spacer()
                                }
                                .padding(.vertical, DS.Spacing.xs)
                                .padding(.horizontal, DS.Spacing.sm)
                                .background(
                                    index == 0
                                        ? AnyShapeStyle(skin.accentColor.opacity(DS.Opacity.lightFill))
                                        : AnyShapeStyle(skin.resolvedPlatterMaterial.opacity(DS.Opacity.softAccent))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    func findBestTime(_ service: OptimizerService) {
        isFindingBestTime = true
        let eventDuration = isPomodoroMode ? TimeInterval(pomodoroTotalMinutes * 60) : duration * 60

        let request = OptimizationRequest(
            .createBlock(title: title, minutes: Int(eventDuration / 60), focus: isPomodoroMode),
            .findSlotsForBacklog,
            .horizon(.today), .speed(.quick), .scenarios(count: 3),
            name: "Find Best Time"
        )

        Task {
            let result = await service.executeRequest(request, reminderService: reminderService)
            isFindingBestTime = false
            if let optimizerResult = result.optimizerResult {
                bestTimeSlots = optimizerResult.scenarios
            }
        }
    }

    func autoSuggestPomodoroSlot(_ service: OptimizerService) {
        isFindingBestTime = true

        let request = OptimizationRequest(
            .pomodoroSession,
            .findSlotsForBacklog,
            .horizon(.today), .speed(.quick), .scenarios(count: 3),
            name: "Pomodoro Slot"
        )

        Task {
            let result = await service.executeRequest(request, reminderService: reminderService)
            isFindingBestTime = false
            if let optimizerResult = result.optimizerResult {
                bestTimeSlots = optimizerResult.scenarios
                // Auto-set date to best slot
                if let bestGene = optimizerResult.scenarios.first?.genes.first {
                    date = bestGene.startTime
                }
            }
        }
    }

}
