import SwiftUI
import BuboDomain
import BuboOptimizer

/// Popover surfaced by ⌥-click on the per-task Schedule button in
/// `BacklogTaskRow`. Shows the top-N candidate slots the GA produced
/// for a single backlog task — the same scenarios the optimizer would
/// have ranked internally before silently committing scenario `[0]`.
/// Clicking a row commits that scenario through
/// `OptimizerService.applyPreviewedScenario`.
///
/// Birman: «show the alternatives, let the user pick». The default
/// click still commits the GA's top pick (no extra friction for the
/// 95% case); ⌥ surfaces the same machinery's runners-up.
struct SlotAlternativesPopover: View {
    /// The backlog task these scenarios were computed for. Used to
    /// locate the task's gene inside each scenario so the row can read
    /// «when does *this* task land in this plan?» rather than printing
    /// the whole schedule.
    let task: BacklogTask
    /// GA scenarios in fitness-rank order (best first). Caller is
    /// responsible for non-empty input — empty popovers shouldn't
    /// open at all (the host shows a toast instead).
    let scenarios: [ScheduleScenario]
    /// Commit the user's pick. Receives the chosen scenario directly;
    /// the host wires it to `applyPreviewedScenario` so undo/learner
    /// bookkeeping run through the standard machinery.
    let onPick: (ScheduleScenario) -> Void
    /// Dismiss without picking. Bound to Esc and click-outside via the
    /// host's `.popover` presentation; the popover itself only needs
    /// it for an explicit Cancel-style escape (none currently shown,
    /// but kept so the contract is symmetric with SlotPickerPopover).
    let onCancel: () -> Void

    @Environment(\.activeSkin) private var skin

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("H:mm")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            header

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scenarios.enumerated()), id: \.element.id) { index, scenario in
                    AlternativeRow(
                        rank: index + 1,
                        slot: slot(for: scenario),
                        movedCount: movedCount(in: scenario),
                        isBest: index == 0,
                        onTap: { onPick(scenario) }
                    )
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        // Esc dismisses without committing — same pattern as
        // SlotPickerPopover but here Esc means «I changed my mind»,
        // not «commit what's queued», because alternatives are
        // single-pick: there's no implicit queue to lose.
        .background(
            Button("", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Schedule \u{201C}\(task.title)\u{201D}")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Spacing.xs)
            Text("\(scenarios.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        Text("Pick a slot — others stay where they are if you skip.")
            .font(.caption)
            .foregroundStyle(skin.resolvedTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Find the gene representing `task` inside a scenario. The GA may
    /// emit multiple matching identifiers — `eventId` for single-block
    /// tasks, `groupId` for split tasks where every chunk references
    /// the parent backlog id, and `reservedTaskIds` for auto-pomodoro
    /// blocks that bundle several backlog rows. The earliest matching
    /// `startTime` is what the user wants to read («when does this
    /// land?»), so we return that.
    private func slot(for scenario: ScheduleScenario) -> (start: Date, end: Date)? {
        let matches = scenario.activeGenes.filter { gene in
            gene.eventId == task.id
                || gene.groupId == task.id
                || gene.reservedTaskIds.contains(task.id)
        }
        guard let first = matches.min(by: { $0.startTime < $1.startTime }) else {
            return nil
        }
        let last = matches.max(by: { $0.endTime < $1.endTime }) ?? first
        return (first.startTime, last.endTime)
    }

    /// Crude «what shifts» metric — the number of *other* events whose
    /// start times move between scenarios. We compare each scenario
    /// against the best (#1) one as a baseline so the user reads each
    /// row as «vs. the top pick, this also reshuffles N events». Cheap
    /// to compute and honest about its precision (it counts moved
    /// genes, not how *much* they move). The best scenario itself
    /// returns 0.
    private func movedCount(in scenario: ScheduleScenario) -> Int {
        guard let baseline = scenarios.first, baseline.id != scenario.id else { return 0 }
        var baselineStarts: [String: Date] = [:]
        for gene in baseline.activeGenes where gene.eventId != task.id {
            baselineStarts[gene.eventId] = gene.startTime
        }
        var moved = 0
        for gene in scenario.activeGenes where gene.eventId != task.id {
            if let prev = baselineStarts[gene.eventId], prev != gene.startTime {
                moved += 1
            }
        }
        return moved
    }
}

/// One alternative slot row. Rank chip + time range + secondary
/// «what shifts» line. Hover paints the row in the soft hover tint
/// shared with `BacklogTaskRow`, so the eye reads them as the same
/// kind of object: a clickable list item.
private struct AlternativeRow: View {
    let rank: Int
    let slot: (start: Date, end: Date)?
    let movedCount: Int
    let isBest: Bool
    let onTap: () -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("H:mm")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                rankBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryLabel)
                        .font(.subheadline.weight(isBest ? .semibold : .regular))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    if let secondary = secondaryLabel {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Spacing.xs)
                if isBest {
                    Text("best")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, DS.Spacing.hairline)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                        )
                }
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(isHovered ? skin.resolvedTextTertiary.opacity(DS.Opacity.subtleFill) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(slot == nil)
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(skin.resolvedTextSecondary)
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(skin.resolvedTextTertiary.opacity(DS.Opacity.subtleFill))
            )
    }

    private var primaryLabel: String {
        guard let slot else { return "No fit" }
        let cal = Calendar.current
        let start = Self.timeFormatter.string(from: slot.start)
        let end = Self.timeFormatter.string(from: slot.end)
        let day: String
        if cal.isDateInToday(slot.start) {
            day = "Today"
        } else if cal.isDateInTomorrow(slot.start) {
            day = "Tomorrow"
        } else {
            day = Self.dayFormatter.string(from: slot.start)
        }
        return "\(day) \u{00B7} \(start)\u{2013}\(end)"
    }

    private var secondaryLabel: String? {
        guard slot != nil else {
            return "The optimizer couldn't place this task in this plan."
        }
        if isBest { return nil }
        if movedCount == 0 { return "Same other events as the best pick." }
        return movedCount == 1
            ? "Also reshuffles 1 other event."
            : "Also reshuffles \(movedCount) other events."
    }

    private var helpText: String {
        guard slot != nil else { return "No fit in this plan" }
        return "Schedule into this slot"
    }

    private var accessibilityLabel: String {
        guard slot != nil else { return "Option \(rank), no fit" }
        let base = "Option \(rank), \(primaryLabel)"
        if let secondary = secondaryLabel {
            return "\(base). \(secondary)"
        }
        return base
    }
}
