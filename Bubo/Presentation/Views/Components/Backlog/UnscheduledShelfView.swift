import SwiftUI
import BuboDomain

// MARK: - Unscheduled shelf
//
// The first block on the main timeline canvas (REDESIGN.md R1): the
// pending backlog surfaced where the user already lives, instead of a
// separate Backlog world. Collapsed by default to one quiet summary
// line — «one screen, one job» means the shelf earns its rows only
// when the user asks.
//
//   ▸ Unscheduled · 3 · ~2 h            (collapsed — one line)
//   ▾ Unscheduled · 3 · ~2 h
//     ○ Write report            1 h     (top rows, drag onto a slot
//     ○ Call mom                30 min   or tap → planner seeded)
//     All tasks →                       (management layer hand-off)
//
// Reuses the `TaskListExpansion` state machine whose inline host was
// deleted in the 2026-06 redesign; rows are `.draggable` with the same
// `BacklogTaskDrag` payload the free-slot drop targets already accept.
struct UnscheduledShelfView: View {

    let tasks: [BacklogTask]
    @Binding var expansion: TaskListExpansion
    /// Row tap — open the planner seeded with this task.
    let onOpenTask: (BacklogTask) -> Void
    /// «All tasks» — hand off to the management layer (fullscreen backlog).
    let onOpenAll: () -> Void

    @Environment(\.activeSkin) private var skin

    /// Compact mode shows at most this many rows; the remainder hides
    /// behind the «All tasks» hand-off so the shelf never crowds the
    /// timeline below it.
    static let compactRowCap = 4

    var body: some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                headerRow

                if expansion != .collapsed {
                    ForEach(tasks.prefix(Self.compactRowCap), id: \.id) { task in
                        row(for: task)
                    }
                    footerRow
                }
            }
            // No horizontal padding of its own: the shelf mounts inside
            // EventList's LazyVStack, which already carries the screen's
            // `contentMargin`. A second margin here double-indented the
            // shelf 32 pt from the edge, knocking it off the one
            // vertical axis the header, Plan rail, and event rows hang
            // on (DS: «all content hangs on one vertical axis»).
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    // MARK: Header

    private var totalMinutes: Int {
        tasks.reduce(0) { $0 + $1.durationMinutes }
    }

    private var headerRow: some View {
        Button {
            Haptics.tap()
            withAnimation(DS.Animation.quick) {
                expansion = expansion.next
            }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                // Disclosure triangle at the leading edge, pointing right
                // when collapsed / down when expanded — the standard macOS
                // disclosure row (HIG disclosure controls: the triangle
                // points inward from the leading edge when content is
                // hidden). It used to trail; leading is where the eye
                // expects the expand affordance.
                Image(systemName: expansion.iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityHidden(true)

                Image(systemName: "tray")
                    .font(.system(size: DS.Size.iconSmall, weight: skin.resolvedSymbolWeight))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityHidden(true)

                Text("Unscheduled")
                    .font(DS.Typography.row(skin: skin))
                    .foregroundStyle(skin.resolvedTextSecondary)

                // Count + volume in the machine voice — the summary IS
                // the collapsed shelf, so it carries the whole fact.
                Text("\(tasks.count) \u{00B7} ~\(DS.formatMinutes(totalMinutes))")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)

                Spacer(minLength: DS.Spacing.sm)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expansion.accessibilityHint)
        .accessibilityLabel(
            "Unscheduled: \(tasks.count) tasks, about \(DS.formatMinutes(totalMinutes))"
        )
        .accessibilityHint(expansion.accessibilityHint)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for task: BacklogTask) -> some View {
        Button {
            Haptics.tap()
            onOpenTask(task)
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityHidden(true)

                Text(task.title)
                    .font(DS.Typography.row(skin: skin))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DS.Spacing.sm)

                Text(DS.formatMinutes(task.durationMinutes))
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .fixedSize()
            }
            .padding(.vertical, DS.Spacing.xxs)
            .padding(.leading, DS.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same payload the free-slot drop targets already accept — a
        // shelf row dragged onto «Free · …» schedules it there via the
        // existing `handleTaskDrop` path.
        .draggable(BacklogTaskDrag(
            taskId: task.id,
            title: task.title,
            durationMinutes: task.durationMinutes,
            context: task.context
        ))
        .help("Plan \u{201C}\(task.title)\u{201D} — or drag it onto a free slot")
        .accessibilityLabel("\(task.title), \(DS.formatMinutes(task.durationMinutes)). Opens the planner.")
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                Haptics.tap()
                onOpenAll()
            } label: {
                Text("All tasks \u{2192}")
                    .font(.footnote)
                    .foregroundStyle(skin.accentColor)
            }
            .buttonStyle(.plain)
            .help("Open the task list")

            if tasks.count > Self.compactRowCap {
                Text("+\(tasks.count - Self.compactRowCap) more")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .padding(.leading, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xxs)
    }
}
