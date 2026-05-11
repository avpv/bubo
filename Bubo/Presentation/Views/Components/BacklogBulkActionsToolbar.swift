import SwiftUI

/// Bottom-anchored bulk-action toolbar for the fullscreen Backlog.
/// Replaces the add-task field while selection mode is on — the user is
/// in «curate the queue» flow, and capturing a new task mid-curation is
/// the wrong rhythm. Counts read live off the host's selection set; an
/// empty set keeps the toolbar visible with disabled actions so leaving
/// the mode is always one tap away.
///
/// Owns no state itself: the host owns the selection set and forwards
/// only the live count plus a closure for each verb. The hidden Done
/// button keeps the `.keyboardShortcut(.cancelAction)` binding wired so
/// Escape still leaves selection mode without a visible affordance.
struct BacklogBulkActionsToolbar: View {
    let count: Int
    /// Whether the host wired an `onScheduleBacklog` callback. Gates the
    /// Schedule segment independently of `hasSelection`.
    let canSchedule: Bool
    let onSchedule: () -> Void
    let onDeferOneDay: () -> Void
    let onDeferOneWeek: () -> Void
    let onFreeze: () -> Void
    let onDelete: () -> Void
    let onDone: () -> Void

    @Environment(\.activeSkin) private var skin

    var body: some View {
        let hasSelection = count > 0
        HStack(spacing: DS.Spacing.sm) {
            Text(count == 0
                ? "Select tasks"
                : "\(count) selected")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(skin.accentColor)
                .contentTransition(.numericText())
                // `fixedSize(horizontal:)` locks the label on a single
                // line. Without it the HStack's space distribution can
                // compress the leading text under pressure from the
                // two trailing capsules — the failure mode produced
                // «1 / select‑/ ed» hyphenated across three lines in
                // the prototype-vs-original screenshot. layoutPriority
                // alone doesn't suffice because the trailing capsules
                // also claim layout priority via their own padding.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            // Primary actions — Schedule / +1d / +7d grouped in a single
            // accent-tinted capsule so they read as one segmented control.
            // Mirrors the prototype's `.sel-group` (flex with 1pt gaps inside
            // a pill background). Compact labels because the prototype hugs
            // a 360pt popover — «+1 day» / «+7 days» would push the second
            // group off-screen.
            HStack(spacing: 1) {
                segmentedBulkButton(
                    label: "Schedule",
                    icon: "calendar.badge.plus",
                    enabled: hasSelection && canSchedule,
                    primary: true,
                    help: "Run the optimizer on the unscheduled subset"
                ) {
                    onSchedule()
                }
                segmentedBulkButton(
                    label: "+1d",
                    icon: "arrow.right",
                    enabled: hasSelection,
                    help: "Push the deadline of every selected task forward by 1 day"
                ) {
                    onDeferOneDay()
                }
                segmentedBulkButton(
                    label: "+7d",
                    icon: "arrow.right.to.line",
                    enabled: hasSelection,
                    help: "Push the deadline of every selected task forward by 1 week"
                ) {
                    onDeferOneWeek()
                }
            }
            .padding(DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
            )

            Spacer(minLength: 0)

            // Utility actions — Freeze + Delete, icon-only, in a quieter
            // grey-tinted capsule so the destructive trash sits visually
            // apart from the primary scheduling verbs.
            HStack(spacing: 1) {
                segmentedBulkIconButton(
                    icon: "snowflake",
                    enabled: hasSelection,
                    help: "Set aside every selected task — they leave the active list but stay in storage",
                    accessibilityLabel: "Freeze selected"
                ) {
                    onFreeze()
                }
                segmentedBulkIconButton(
                    icon: "trash",
                    enabled: hasSelection,
                    destructive: true,
                    help: "Delete every selected task (undoable)",
                    accessibilityLabel: "Delete selected"
                ) {
                    onDelete()
                }
            }
            .padding(DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.resolvedTextTertiary.opacity(DS.Opacity.subtleFill))
            )

            // Hidden Done — keyboard-only exit. The visible toolbar
            // mirrors the prototype's chrome-light single-row design;
            // Escape still leaves selection mode without a visible
            // button for users who depend on the keyboard.
            Button("Done") { onDone() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            Rectangle()
                .fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
        .overlay(alignment: .top) {
            // Hairline accent on top edge — same role as the
            // prototype's `.sel-bar { border-top: 0.5px solid ... }`,
            // separating the action bar from the task list above
            // without claiming a full divider.
            Rectangle()
                .fill(skin.accentColor.opacity(DS.Opacity.softAccent))
                .frame(height: 0.5)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Single button inside an accent-tinted segmented capsule —
    /// label + optional icon, transparent fill (the parent capsule
    /// carries the visual). `primary: true` paints the foreground in
    /// accent so Schedule reads as the dominant verb in its group;
    /// otherwise text is secondary so +1d/+7d sit visually quieter
    /// than the Schedule sibling.
    @ViewBuilder
    private func segmentedBulkButton(
        label: String,
        icon: String,
        enabled: Bool,
        primary: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(
                primary ? skin.accentColor : skin.resolvedTextSecondary
            )
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .frame(minHeight: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : DS.Opacity.tertiaryText)
        .help(help)
        .accessibilityLabel(label)
    }

    /// Icon-only segment for the utility group (Freeze / Delete).
    /// Same transparent-on-pill chrome as `segmentedBulkButton`; the
    /// `destructive` flag paints the trash glyph in destructive red
    /// so the irreversible action stays distinguishable from freeze.
    @ViewBuilder
    private func segmentedBulkIconButton(
        icon: String,
        enabled: Bool,
        destructive: Bool = false,
        help: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(
                    destructive
                        ? AnyShapeStyle(skin.resolvedDestructiveColor)
                        : AnyShapeStyle(skin.resolvedTextSecondary)
                )
                .frame(minWidth: 28, minHeight: 22)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : DS.Opacity.tertiaryText)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}
