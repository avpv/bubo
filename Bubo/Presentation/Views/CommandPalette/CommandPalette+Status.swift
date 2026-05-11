import SwiftUI

// MARK: - Command Palette: Status, Applied, Failed views
//
// Result surfaces after a run completes (success or error).
// Extracted from CommandPalette.swift.

extension CommandPalette {

    // MARK: - Status Views

    func statusView(_ label: String, intentName: String?) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(skin.accentColor)
                .symbolEffect(.pulse, isActive: true)
            if let intentName, !intentName.isEmpty {
                Text(intentName)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)

            Button("Cancel") { cancelWorking() }
                .buttonStyle(.action(role: .secondary, size: .compact))
                .padding(.top, DS.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    func cancelWorking() {
        workingTask?.cancel()
        workingTask = nil
        Haptics.tap()
        withAnimation(DS.Animation.quick) { phase = .picking }
    }

    func appliedView(_ events: [EventInfo], resolutions: [ActionableResolution]) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(skin.resolvedSuccessColor)
            ForEach(events) { info in
                HStack(spacing: DS.Spacing.xs) {
                    Text(info.title).font(.subheadline.weight(.medium))
                    Text(info.timeRange).font(.subheadline.monospacedDigit()).foregroundStyle(skin.accentColor)
                }
            }
            if let notice = appliedNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            
            if !resolutions.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(resolutions) { res in
                        Button(res.title) {
                            var newReq = lastExecutedRequest ?? composedRequest ?? OptimizationRequest()
                            newReq.merge(res.modifier)
                            runRequest(newReq)
                        }
                        .buttonStyle(.action(role: .secondary, size: .compact))
                    }
                }
                .padding(.top, DS.Spacing.sm)
            }

            Button("Undo") {
                optimizerService.undoLast(reminderService: reminderService)
                let resolutions = [
                    ActionableResolution(title: "Too dense", modifier: OptimizationRequest(.addBuffer(minutes: 15))),
                    ActionableResolution(title: "Too late", modifier: OptimizationRequest(.noEventsAfter(hour: 18))),
                    ActionableResolution(title: "Move to tomorrow", modifier: OptimizationRequest(.horizon(.tomorrow)))
                ]
                withAnimation(DS.Animation.quick) {
                    phase = .failed(message: "Why did you undo?", resolutions: resolutions)
                }
            }
            .buttonStyle(.action(role: .secondary, size: .compact))
            .padding(.top, DS.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
    }

    func failedView(_ message: String, resolutions: [ActionableResolution]) -> some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(skin.resolvedWarningColor)
            Text(message)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            
            if !resolutions.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(resolutions) { res in
                        Button(res.title) {
                            var newReq = lastExecutedRequest ?? composedRequest ?? OptimizationRequest()
                            newReq.merge(res.modifier)
                            runRequest(newReq)
                        }
                        .buttonStyle(.action(role: .secondary, size: .compact))
                    }
                }
                .padding(.top, DS.Spacing.sm)
            }

            HStack(spacing: DS.Spacing.sm) {
                Button("Back") {
                    withAnimation(DS.Animation.quick) { phase = .picking }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.accentColor)
                .buttonStyle(.plain)
                
                Button("Close") { onDismiss() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .buttonStyle(.plain)
            }
            .padding(.top, resolutions.isEmpty ? 0 : DS.Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

}
