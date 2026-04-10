import SwiftUI

// MARK: - Quick Actions
//
// Context-aware action buttons ranked by algorithm.
// One tap → execute → undo toast. No palette needed.
//
// Ranking: HN-inspired score = (usage × context) / time^gravity
// Most relevant actions float to top. Irrelevant ones hidden.

struct QuickActions: View {
    @Environment(\.activeSkin) private var skin

    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onExecuted: (_ label: String, _ undo: @escaping () -> Void) -> Void
    var onOpenPalette: () -> Void

    @State private var isRunning = false

    private var rankedActions: [QuickActionRanker.ScoredAction] {
        guard let backlog = optimizerService.backlogService else { return [] }
        let ranker = QuickActionRanker(
            backlogService: backlog,
            reminderService: reminderService,
            intentLearner: optimizerService.intentLearner
        )
        return ranker.rank(limit: 3)
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Palette button — first, most powerful action
            Button {
                Haptics.tap()
                onOpenPalette()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.semibold))
                    Text("Optimize")
                        .font(.caption.weight(.medium))
                    Text("⌘K")
                        .font(.caption2.monospaced())
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(skin.accentColor.opacity(0.10))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("AI optimizer (\u{2318}K)")

            ForEach(rankedActions) { scored in
                Button {
                    run(scored.action)
                } label: {
                    Text(scored.action.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(0.10))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .opacity(isRunning ? 0.5 : 1)
            }
        }
    }

    private func run(_ action: QuickActionCandidate) {
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
}
