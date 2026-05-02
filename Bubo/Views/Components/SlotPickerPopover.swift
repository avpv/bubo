import SwiftUI

/// Inline picker shown when the user taps the «+» on a free time slot
/// in the timeline. Replaces the legacy command-palette seeding flow:
/// instead of bouncing the user to a separate surface, this popover
/// presents the two real intents directly — pick an existing backlog
/// task, or type a new one — and places it into this exact slot.
///
/// Birman: «прямое действие на месте проблемы». The slot is the
/// cursor's current focus, and so is the popover.
///
/// State is local: a draft title that the user types into. Enter
/// commits — if a candidate row was tapped, that existing task is
/// scheduled; otherwise a new task is created at the parsed
/// duration and scheduled. Esc dismisses without effect.
struct SlotPickerPopover: View {
    /// Slot start time — defines where the placed event will land.
    let slotStart: Date
    /// Slot end time — caps the placed event's duration.
    let slotEnd: Date
    /// Backlog tasks the user might want to pull into this slot.
    /// Caller filters to the `pending` set; the picker ranks and renders.
    let tasks: [BacklogTask]
    /// Place an existing backlog task into the slot.
    let onPick: (BacklogTask) -> Void
    /// Create a new backlog task with this title + duration and place
    /// it into the slot. Duration falls back to slot length when the
    /// user hasn't typed an explicit «… 45m» suffix.
    let onCreate: (_ title: String, _ durationMinutes: Int) -> Void
    /// Open the fullscreen backlog (user wants to browse the full
    /// list, not just the top N candidates). nil hides the row.
    var onOpenFullscreenBacklog: (() -> Void)? = nil
    /// Dismiss without action — bound to Esc.
    let onCancel: () -> Void

    @Environment(\.activeSkin) private var skin
    @State private var draftTitle: String = ""
    @FocusState private var isInputFocused: Bool

    private var slotMinutes: Int {
        max(0, Int(slotEnd.timeIntervalSince(slotStart) / 60))
    }

    private var slotRangeLabel: String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return "\(fmt.string(from: slotStart))\u{2013}\(fmt.string(from: slotEnd))"
    }

    private var slotDurationLabel: String {
        if slotMinutes < 60 { return "\(slotMinutes)\u{00A0}min" }
        let h = slotMinutes / 60
        let m = slotMinutes % 60
        return m == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h \(m)\u{00A0}min"
    }

    /// Coarse Phase-1 ranking: urgent first, then duration-fit, then by
    /// most recently created. Replaced by `TimelineSlotRanker` in
    /// Phase 2 with proper signals (context match, energy, etc.).
    private var rankedCandidates: [BacklogTask] {
        let now = Date()
        return tasks
            .filter { $0.status == .pending }
            .sorted { lhs, rhs in
                let lu = BacklogLogic.isUrgent(lhs, now: now)
                let ru = BacklogLogic.isUrgent(rhs, now: now)
                if lu != ru { return lu }
                let lf = lhs.durationMinutes <= slotMinutes
                let rf = rhs.durationMinutes <= slotMinutes
                if lf != rf { return lf }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private var visibleCandidates: [BacklogTask] {
        Array(rankedCandidates.prefix(5))
    }

    private var canCreate: Bool {
        !draftTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Header — slot range + duration in the «machine speech» voice,
            // so it reads as the popover's own tag rather than a label
            // belonging to the input below.
            Text("\(slotRangeLabel) · \(slotDurationLabel)")
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)

            // Input — autofocused on appear so the user can start typing
            // immediately. Enter creates+places via `submit()`.
            TextField("Add a task or pick from below\u{2026}", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isInputFocused)
                .onSubmit(submit)
                .padding(.vertical, DS.Spacing.xxs)

            // Hairline between input and candidate list — same role as
            // the meta→content seam in the backlog.
            SkinSeparator()

            // Candidates: top N from `rankedCandidates`. Empty → gentle
            // hint that this is also a creation surface.
            if visibleCandidates.isEmpty {
                Text(tasks.isEmpty
                     ? "No backlog tasks yet — type to create one."
                     : "No matching tasks — type to create one.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.vertical, DS.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleCandidates, id: \.id) { task in
                        candidateRow(for: task)
                    }
                }
            }

            // Footer — only when there's more to browse than the visible top-N.
            if let onOpenFullscreenBacklog,
               rankedCandidates.count > visibleCandidates.count {
                SkinSeparator()
                Button {
                    Haptics.tap()
                    onOpenFullscreenBacklog()
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Text("Show all \(rankedCandidates.count) tasks")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextSecondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, DS.Spacing.xs)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.md)
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 400)
        .onAppear { isInputFocused = true }
        // Esc dismiss — `keyboardShortcut(.cancelAction)` on a hidden
        // button is SwiftUI's canonical pattern for binding Esc when
        // there's no visible Cancel button.
        .background(
            Button("", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder
    private func candidateRow(for task: BacklogTask) -> some View {
        Button { onPick(task) } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                if BacklogLogic.isUrgent(task) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedDestructiveColor)
                        .accessibilityHidden(true)
                }

                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DS.Spacing.sm)

                Text(durationLabel(task.durationMinutes))
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)

                if task.durationMinutes > slotMinutes {
                    Text("won't fit")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary.opacity(0.7))
                }
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    private func submit() {
        guard canCreate else { return }
        let parsed = BacklogTitleParser.parse(draftTitle)
        let duration = parsed.durationMinutes ?? slotMinutes
        Haptics.tap()
        onCreate(parsed.cleaned, duration)
    }
}
