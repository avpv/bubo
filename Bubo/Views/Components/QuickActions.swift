import SwiftUI

// MARK: - Quick Actions
//
// 2-3 context-aware action buttons in the footer.
// One tap → execute → undo toast. No palette, no configuration.
//
// Birman: "Пусть потеет машина" — system picks the right actions.
// Buttons change based on what's happening in the schedule.

struct QuickActions: View {
    @Environment(\.activeSkin) private var skin

    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onExecuted: (_ label: String, _ undo: @escaping () -> Void) -> Void
    var onOpenPalette: () -> Void

    @State private var isRunning = false

    private var actions: [QuickAction] {
        var result: [QuickAction] = []
        let pending = optimizerService.backlogService?.pending ?? []
        let urgent = optimizerService.backlogService?.urgent(withinDays: 2) ?? []
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let todayEvents = reminderService.allEvents.filter { $0.startDate >= now && $0.startDate < todayEnd }
        let hasFocus = todayEvents.contains { $0.eventType == .pomodoro }

        // Priority order — show most relevant 2 actions
        if !urgent.isEmpty {
            result.append(QuickAction(
                label: "Deadlines",
                icon: "exclamationmark.circle.fill",
                request: .deadlineMode
            ))
        }

        if !pending.isEmpty {
            result.append(QuickAction(
                label: "Schedule \(pending.count)",
                icon: "calendar.badge.plus",
                request: .scheduleBacklog
            ))
        }

        if !hasFocus && hour < 15 && result.count < 2 {
            result.append(QuickAction(
                label: "Focus",
                icon: "scope",
                request: .findFocus()
            ))
        }

        if hour < 10 && todayEvents.count >= 3 && result.count < 2 {
            result.append(QuickAction(
                label: "Organize",
                icon: "wand.and.stars",
                request: .organizeDay
            ))
        }

        return Array(result.prefix(2))
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(actions) { action in
                Button {
                    run(action)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: action.icon)
                            .font(.caption2.weight(.semibold))
                        Text(action.label)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(skin.accentColor)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(skin.accentColor.opacity(0.10))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .opacity(isRunning ? 0.5 : 1)
            }

            // Palette button (always present)
            Button {
                Haptics.tap()
                onOpenPalette()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.medium))
                    Text("⌘K")
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(skin.resolvedTextTertiary.opacity(0.35), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("⌘K")
        }
    }

    private func run(_ action: QuickAction) {
        Haptics.tap()
        isRunning = true

        Task {
            let result = await optimizerService.executeRequest(
                action.request,
                reminderService: reminderService
            )

            await MainActor.run {
                isRunning = false

                switch result {
                case .success, .partialSuccess:
                    guard !optimizerService.scenarios.isEmpty else { return }
                    optimizerService.applyScenario(at: 0, to: reminderService)
                    onExecuted(action.label) {
                        optimizerService.undoLast(reminderService: reminderService)
                    }
                default:
                    break
                }
            }
        }
    }

    struct QuickAction: Identifiable {
        let id = UUID()
        let label: String
        let icon: String
        let request: OptimizationRequest
    }
}
