import SwiftUI

// MARK: - Backlog Tombstones

/// Shared «квартирант, а не жилец» summary rows for completed-today and
/// frozen tasks. Used by both the inline `BacklogView` (under the active
/// list) and the fullscreen `SprintView` (at the bottom of its scroll).
///
/// Pre-extraction the two views had ~150 lines of near-identical tombstone
/// code each, kept in sync by hand. Whenever someone touched the snowflake
/// row in one place we'd have to remember the other; in practice the two
/// drifted (SprintView lost the leading-gutter alignment, the row-height
/// floor, etc.) and the views looked subtly different even though they
/// were rendering the same data.
///
/// Design (Birman):
/// - Both tombstones are summaries first, lists second: chevron + count
///   are always visible, the rows themselves expand on tap. Completed
///   today never crowds the active list, frozen tasks stay reachable
///   without occupying mental space.
/// - One tap restores: a click on the filled checkmark uncompletes,
///   a click on the snowflake unfreezes. No confirm dialogs — undo lives
///   in the toast pipe owned by the parent.
/// - Visual continuity with the active list above is opt-in (the
///   `alignedLeadingGutter` and `minRowHeight` knobs) so SprintView,
///   which has no leading icon column to line up with, doesn't pay for
///   alignment it doesn't need.
struct BacklogTombstones: View {
    let completedToday: [BacklogTask]
    let frozen: [BacklogTask]
    @Binding var showCompleted: Bool
    @Binding var showFrozen: Bool

    /// When true, completed/frozen rows render with a leading gutter that
    /// matches the leading-icon column of active task rows in `BacklogView`,
    /// so the checkmark/snowflake column visually aligns with the active
    /// rows above. `SprintView` passes `false` — its rows have no leading
    /// column to align with.
    var alignedLeadingGutter: Bool = false

    /// Floor for tombstone-row height. BacklogView passes its
    /// `compactRowHeight` (40pt) so completed/frozen rows match the active
    /// row height above them; SprintView leaves it nil and lets content
    /// size dictate.
    var minRowHeight: CGFloat? = nil

    /// Restore a completed task to the active list. Parent owns the
    /// `BacklogService` mutation + undo toast; the tombstone only fires.
    let onUncomplete: (BacklogTask) -> Void
    /// Unfreeze a single frozen task. Same split as `onUncomplete`.
    let onUnfreezeOne: (BacklogTask) -> Void
    /// Batch-unfreeze every frozen task. Surfaced as the «Unfreeze all»
    /// shortcut next to the frozen header — frozen tasks are typically
    /// thawed in groups when priorities shift.
    let onUnfreezeAll: () -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            completedTombstone
            frozenTombstone
        }
    }

    // MARK: - Completed-today

    @ViewBuilder
    private var completedTombstone: some View {
        if !completedToday.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                        showCompleted.toggle()
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .contentTransition(.symbolEffect(.replace))
                        Text("\(completedToday.count) completed today")
                            .font(.caption2.monospacedDigit())
                            .contentTransition(.numericText())
                        Spacer()
                    }
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(completedToday.count) tasks completed today")
                .accessibilityHint(showCompleted ? "Hide completed" : "Show completed")

                if showCompleted {
                    ForEach(completedToday) { task in
                        completedRow(task)
                            .transition(.opacity)
                    }
                }
            }
            .motionAwareAnimation(DS.Animation.standard, value: showCompleted, reduceMotion: reduceMotion)
            .motionAwareAnimation(DS.Animation.quick, value: completedToday.map(\.id), reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private func completedRow(_ task: BacklogTask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            if alignedLeadingGutter {
                // Reserve the same leading gutter as active rows so the
                // checkmark column aligns vertically — keeps the two lists
                // visually linked when stacked under one another.
                Color.clear
                    .frame(width: DS.Size.iconLarge, height: DS.Size.accentBarHeight)
            }

            Button {
                onUncomplete(task)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore task")
            .accessibilityLabel("Restore \u{201C}\(task.title)\u{201D}")

            Text(task.title)
                .font(.callout)
                .foregroundStyle(skin.resolvedTextTertiary)
                .strikethrough()
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: minRowHeight ?? .leastNonzeroMagnitude)
    }

    // MARK: - Frozen

    @ViewBuilder
    private var frozenTombstone: some View {
        if !frozen.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                            showFrozen.toggle()
                        }
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: showFrozen ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .contentTransition(.symbolEffect(.replace))
                            Image(systemName: "snowflake")
                                .font(.caption2)
                            Text("\(frozen.count) frozen")
                                .font(.caption2.monospacedDigit())
                                .contentTransition(.numericText())
                            Spacer()
                        }
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(frozen.count) frozen tasks")

                    Button("Unfreeze all") {
                        onUnfreezeAll()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.accentColor)
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xs)

                if showFrozen {
                    ForEach(frozen) { task in
                        frozenRow(task)
                            .transition(.opacity)
                    }
                }
            }
            .motionAwareAnimation(DS.Animation.standard, value: showFrozen, reduceMotion: reduceMotion)
            .motionAwareAnimation(DS.Animation.quick, value: frozen.map(\.id), reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private func frozenRow(_ task: BacklogTask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            if alignedLeadingGutter {
                Color.clear
                    .frame(width: DS.Size.iconLarge, height: DS.Size.accentBarHeight)
            }

            Button {
                onUnfreezeOne(task)
            } label: {
                Image(systemName: "snowflake")
                    .font(.callout)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unfreeze task")
            .accessibilityLabel("Unfreeze \u{201C}\(task.title)\u{201D}")

            Text(task.title)
                .font(.callout)
                .foregroundStyle(skin.resolvedTextTertiary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: minRowHeight ?? .leastNonzeroMagnitude)
    }
}
