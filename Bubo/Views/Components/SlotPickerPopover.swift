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

    // MARK: - Filter state
    //
    // Same vocabulary as `BacklogFullscreenView` — smart filter, project,
    // colour tag — so the user transfers one mental model across both
    // surfaces. State is local: the picker is a transient anchored
    // popover, persisting filters across opens would feel like
    // state-creep. Phase 5 will extract these chips to a shared
    // `BacklogFilterChipsRow` component.

    /// One-of-N status/deadline view restriction (Apple Reminders-style
    /// «view as…»). nil = no restriction.
    @State private var smartFilter: BacklogLogic.SmartFilter? = nil
    /// Project / context filter chip. nil = all projects.
    @State private var projectFilter: String? = nil
    /// Colour tag chip. nil = all colours.
    @State private var colorFilter: EventColorTag? = nil

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

    /// Pending pool — all picker logic operates over this. The caller
    /// already passes `BacklogService.pending`, but we re-filter here
    /// defensively so the chip-count helpers don't accidentally include
    /// scheduled / done / frozen rows.
    private var pendingPool: [BacklogTask] {
        tasks.filter { $0.status == .pending }
    }

    /// Distinct project labels in the pending pool. Drives the project
    /// chips and the «hide chip row» gate.
    private var availableProjects: [String] {
        let raw = pendingPool.compactMap { $0.context?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(raw)).sorted()
    }

    /// Distinct colour tags in the pending pool.
    private var availableColorTags: [EventColorTag] {
        let raw = pendingPool.compactMap { $0.colorTag }
        return Array(Set(raw)).sorted { $0.rawValue < $1.rawValue }
    }

    /// `(filter → count)` over the pending pool, mirroring the fullscreen
    /// backlog. Pre-computed in one pass so the chip row renders without
    /// re-scanning per chip.
    private var smartFilterCounts: [BacklogLogic.SmartFilter: Int] {
        BacklogLogic.smartFilterCounts(pendingPool)
    }

    /// True when at least one smart-filter chip carries a non-zero count
    /// (other than the always-present «All»). Falls to false on calm
    /// backlogs so we don't render a row of just «All · N».
    private var hasAnySmartChip: Bool {
        BacklogLogic.SmartFilter.allCases.contains { (smartFilterCounts[$0] ?? 0) > 0 }
    }

    /// Whether the chip row is worth rendering at all. Small backlogs
    /// (no projects, no colours, no flagged/today/overdue) skip it
    /// entirely so the popover stays compact.
    private var hasAnyChips: Bool {
        hasAnySmartChip || !availableProjects.isEmpty || !availableColorTags.isEmpty
    }

    /// Pending pool narrowed by the user-selected filter chips. Composes
    /// AND, same order as `BacklogFullscreenView`.
    private var filteredPool: [BacklogTask] {
        var result = pendingPool
        if let smart = smartFilter {
            result = result.filter { BacklogLogic.matchesSmartFilter($0, filter: smart) }
        }
        if let project = projectFilter {
            result = result.filter { ($0.context ?? "") == project }
        }
        if let color = colorFilter {
            result = result.filter { $0.colorTag == color }
        }
        return result
    }

    /// Coarse Phase-1 ranking applied AFTER the filter chips: urgent
    /// first, then duration-fit, then by most recently created.
    /// Replaced by `TimelineSlotRanker` in Phase 2 with proper signals
    /// (context match, energy, etc.).
    private var rankedCandidates: [BacklogTask] {
        let now = Date()
        return filteredPool.sorted { lhs, rhs in
            let lu = BacklogLogic.isUrgent(lhs, now: now)
            let ru = BacklogLogic.isUrgent(rhs, now: now)
            if lu != ru { return lu }
            let lf = lhs.durationMinutes <= slotMinutes
            let rf = rhs.durationMinutes <= slotMinutes
            if lf != rf { return lf }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// True when at least one filter is engaged — drives the empty-state
    /// copy («adjust filters or type to create» vs the calm version).
    private var hasActiveFilter: Bool {
        smartFilter != nil || projectFilter != nil || colorFilter != nil
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

            // Filter chips — same vocabulary as the fullscreen backlog
            // (smart filter → project → colour). Hidden on calm backlogs
            // where there's nothing to filter so the popover stays
            // compact for the common case.
            if hasAnyChips {
                filterChipsRow
                SkinSeparator()
            }

            // Candidates: top N from `rankedCandidates`. Empty → gentle
            // hint that this is also a creation surface; copy adapts to
            // whether a filter is hiding the matches.
            if visibleCandidates.isEmpty {
                Text(emptyCandidateMessage)
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

    /// Empty-state copy. Three voices: never created any tasks (calm),
    /// has tasks but a filter is hiding the matches (actionable), has
    /// tasks but none match the slot's other constraints (rare — same
    /// hint as the calm form to avoid a third special case).
    private var emptyCandidateMessage: String {
        if pendingPool.isEmpty {
            return "No backlog tasks yet — type to create one."
        }
        if hasActiveFilter {
            return "No tasks match the active filters — adjust them or type to create."
        }
        return "No matching tasks — type to create one."
    }

    // MARK: - Filter chips
    //
    // Mirrors `BacklogFullscreenView`'s `smartFilterRow` / `filterChipsRow`
    // exactly — same chip shapes, same divider between smart-filter
    // group and project/colour group, same auto-hide rules. Phase 5
    // will extract a shared `BacklogFilterChipsRow` so both surfaces
    // can't drift.

    @ViewBuilder
    private var filterChipsRow: some View {
        let counts = smartFilterCounts
        let projects = availableProjects
        let colors = availableColorTags
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                if hasAnySmartChip {
                    smartFilterChip(filter: nil, count: pendingPool.count)
                    ForEach(BacklogLogic.SmartFilter.allCases, id: \.self) { filter in
                        let count = counts[filter] ?? 0
                        // Hide zero-count chips except the active one —
                        // user needs an escape from an empty-filtered view.
                        if count > 0 || smartFilter == filter {
                            smartFilterChip(filter: filter, count: count)
                        }
                    }
                }

                if hasAnySmartChip && (!projects.isEmpty || !colors.isEmpty) {
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, DS.Spacing.xxs)
                }

                ForEach(projects, id: \.self) { project in
                    projectChip(project)
                }

                if !projects.isEmpty && !colors.isEmpty {
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, DS.Spacing.xxs)
                }

                ForEach(colors, id: \.rawValue) { color in
                    colorChip(color)
                }
            }
            .padding(.vertical, DS.Spacing.xxs)
        }
    }

    @ViewBuilder
    private func smartFilterChip(
        filter: BacklogLogic.SmartFilter?,
        count: Int
    ) -> some View {
        let isOn = smartFilter == filter
        let label = filter?.label ?? "All"
        let icon = filter?.systemImage ?? "tray.full"
        Button {
            Haptics.tap()
            // Tap the active chip to clear back to "All"; tap "All"
            // when already on "All" is a no-op (no surprise toggle).
            if isOn {
                smartFilter = nil
            } else {
                smartFilter = filter
            }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption.weight(isOn ? .semibold : .regular))
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .foregroundStyle(isOn ? skin.accentColor : skin.resolvedTextSecondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.accentColor.opacity(isOn ? DS.Opacity.lightFill : 0))
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.accentColor.opacity(isOn ? DS.Opacity.softAccent : DS.Opacity.borderIdle),
                    lineWidth: DS.Border.thin
                )
            )
        }
        .buttonStyle(.plain)
        .help(
            isOn
                ? "Showing only \(label.lowercased()) — tap to clear"
                : (filter == nil
                    ? "Show all pending tasks"
                    : "Filter to \(label.lowercased()) tasks")
        )
    }

    @ViewBuilder
    private func projectChip(_ project: String) -> some View {
        let isOn = projectFilter == project
        Button {
            Haptics.tap()
            projectFilter = isOn ? nil : project
        } label: {
            Text(project)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? skin.accentColor : skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(
                    Capsule().fill(skin.accentColor.opacity(isOn ? DS.Opacity.lightFill : 0))
                )
                .overlay(
                    Capsule().strokeBorder(
                        skin.accentColor.opacity(isOn ? DS.Opacity.softAccent : DS.Opacity.borderIdle),
                        lineWidth: DS.Border.thin
                    )
                )
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing tasks in \u{201C}\(project)\u{201D} — tap to clear" : "Filter to \u{201C}\(project)\u{201D}")
    }

    @ViewBuilder
    private func colorChip(_ color: EventColorTag) -> some View {
        let isOn = colorFilter == color
        Button {
            Haptics.tap()
            colorFilter = isOn ? nil : color
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 10, height: 10)
                .padding(.horizontal, DS.Spacing.xxs)
                .padding(.vertical, DS.Spacing.xxs)
                .overlay(
                    Capsule().strokeBorder(
                        skin.accentColor.opacity(isOn ? DS.Opacity.softAccent : 0),
                        lineWidth: DS.Border.thin
                    )
                )
                .padding(.horizontal, DS.Spacing.xxs)
                .background(
                    Capsule().fill(color.color.opacity(isOn ? DS.Opacity.subtleFill : 0))
                )
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing only \(color.rawValue) tasks — tap to clear" : "Filter to \(color.rawValue) tasks")
    }
}
