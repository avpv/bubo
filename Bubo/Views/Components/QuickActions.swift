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
    var onError: (_ message: String) -> Void = { _ in }
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
        // Horizontal scroll wrapper keeps the HStack's natural width from
        // forcing the whole cardified main-screen layout wider than the
        // popover. Without this, fixedSize chips (Optimize + up to 3 ranked
        // actions, ~360pt total) overflow the 328pt card content area,
        // which cascades up through `.frame(maxWidth: .infinity)` into
        // the card wrapper, then into the VStack parent — every main-screen
        // card ends up wider than the 360pt popover, causing asymmetric
        // left/right margins and right-edge clipping. The ScrollView
        // contains the overflow inside its own viewport.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                // Palette button — the primary optimizer entry point. Level 3:
                // solid accent fill + contrasting foreground so it reads as THE
                // primary action of the row; secondary chips keep a muted tint.
                Button {
                    Haptics.tap()
                    onOpenPalette()
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Group {
                            if isRunning {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(primaryForeground)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                        Text("Optimize")
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Text("⌘K")
                            .font(.footnote.monospaced())
                            .foregroundStyle(primaryForeground.opacity(DS.Opacity.accentMuted))
                    }
                    .fixedSize()
                    .foregroundStyle(primaryForeground)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.pillVertical)
                    .background(
                        Capsule().fill(skin.accentColor)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            Color.white.opacity(0.25),
                            lineWidth: DS.Border.thin
                        )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .opacity(isRunning ? DS.Opacity.overlayLight : 1)
                .help("AI optimizer (\u{2318}K)")

                ForEach(rankedActions) { scored in
                    Button {
                        run(scored.action)
                    } label: {
                        Text(scored.action.label)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(skin.accentColor)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, DS.Spacing.pillVertical)
                            .background(
                                Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                    .opacity(isRunning ? DS.Opacity.half : 1)
                    // «Why is this chip here?» — chips swap in/out as context
                    // shifts, and без подсказки выглядят как фокусы. Tooltip
                    // показывает сигнал, который вынес действие в top-3,
                    // делая ранжер видимой машинерией, а не магией.
                    .help(scored.reason.isEmpty ? scored.action.label : scored.reason)
                }
            }
        }
        // Pin the ScrollView's height to its content so it doesn't
        // vertically expand inside the card.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Foreground used on top of the solid accent fill — picks black or
    /// white depending on the accent colour's luminance so contrast never
    /// breaks on light accents.
    private var primaryForeground: Color {
        DS.contrastingForeground(for: skin.accentColor)
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
                case .noEventsToOptimize, .infeasible:
                    if let msg = result.errorMessage {
                        onError(msg)
                    }
                }
            }
        }
    }
}
