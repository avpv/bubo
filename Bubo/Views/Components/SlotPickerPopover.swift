import SwiftUI

// MARK: - Commit item
//
// One unit of work the user has queued inside the picker session.
// Either a reference to an existing backlog task or a freshly typed
// title that should be created and placed at commit time. The host
// receives an ordered list of these on dismiss and turns them into
// back-to-back calendar events under a single undo toast.

/// One queued placement inside `SlotPickerPopover`. Lives at file scope
/// (rather than nested in the popover) so the host can spell the type
/// in its callback signature without leaking SwiftUI generic noise.
enum SlotPickerCommitItem {
    /// Reference to a task already in the backlog.
    case existing(BacklogTask)
    /// New task typed into the input. `stagingId` is a local identity
    /// so the queue can render and remove it before a real `BacklogTask.id`
    /// exists; the host mints the persistent id at commit time.
    case create(stagingId: UUID, title: String, durationMinutes: Int)

    /// Minutes this item will occupy when placed. The picker sums these
    /// to derive the «remaining» readout — keeping it consistent with
    /// what the host will actually schedule.
    var durationMinutes: Int {
        switch self {
        case .existing(let task): return task.durationMinutes
        case .create(_, _, let m): return m
        }
    }

    /// Human-readable label used by both the in-queue badge and the
    /// single-item toast wording. Matches the title the host will
    /// place on the calendar event.
    var displayTitle: String {
        switch self {
        case .existing(let t): return t.title
        case .create(_, let title, _): return title
        }
    }

    /// Stable identity for the queue's `ForEach` and for «toggle off»
    /// on a re-tap of the same backlog row. `existing` aliases on the
    /// backlog id so a second tap on the same row finds the queued
    /// entry; `create` aliases on its staging UUID since two creates
    /// with the same title are still distinct items.
    var queueKey: String {
        switch self {
        case .existing(let t): return "existing-\(t.id)"
        case .create(let id, _, _): return "create-\(id.uuidString)"
        }
    }
}

/// Inline picker shown when the user taps the «+» on a free time slot
/// in the timeline. Replaces the legacy command-palette seeding flow:
/// instead of bouncing the user to a separate surface, this popover
/// presents the two real intents directly — pick existing backlog
/// tasks, or type new ones — and places them all back-to-back inside
/// this exact slot.
///
/// Birman: «direct action at the site of the problem». The slot is the
/// cursor's current focus, and so is the popover.
///
/// Picks accumulate locally inside the popover and commit as a single
/// batch on dismissal — Done button, Esc, or click-outside. This lets
/// the user fill a 4-hour gap with four 1-hour tasks in a single
/// gesture loop and undo the whole placement in one toast.
struct SlotPickerPopover: View {
    /// Slot start time — defines where the first placed event lands.
    let slotStart: Date
    /// Slot end time — caps the total queued duration.
    let slotEnd: Date
    /// Backlog tasks the user might want to pull into this slot.
    /// Caller filters to the `pending` set; the picker ranks and renders.
    let tasks: [BacklogTask]
    /// Events near the slot on the same day — used by
    /// `TimelineSlotRanker` for context-match scoring («I'm bracketed
    /// by Project X, surface Project X tasks first»). Empty list =
    /// context signal effectively zero, ranker falls back on the
    /// other signals.
    var adjacentEvents: [CalendarEvent] = []
    /// Commit the queued placements. Ordered list — host places them
    /// back-to-back from `slotStart`, capped at `slotEnd`. Empty list
    /// is a no-op (user opened the picker and dismissed without
    /// queueing anything). Called exactly once per popover lifecycle
    /// regardless of which dismissal path fires (Done / Esc / click-
    /// outside) thanks to the internal `didCommit` guard.
    let onCommit: (_ items: [SlotPickerCommitItem]) -> Void
    /// Open the fullscreen backlog (user wants to browse the full
    /// list, not just the top N candidates). nil hides the row.
    /// Selecting this implicitly commits anything already queued —
    /// the host swaps surfaces, it doesn't drop work.
    var onOpenFullscreenBacklog: (() -> Void)? = nil

    @Environment(\.activeSkin) private var skin
    @State private var draftTitle: String = ""
    @FocusState private var isInputFocused: Bool

    // MARK: - Queue state
    //
    // Local-only — the picker holds onto picks and creates until the
    // user closes the popover. Nothing reaches the schedule until
    // `commit()` fires, so the user can change their mind freely
    // without polluting undo history with half-formed sessions.

    /// Ordered queue of placements. Renders as in-line «added» badges
    /// on candidate rows and as ghost ranges in the header readout.
    @State private var queue: [SlotPickerCommitItem] = []

    /// Latch so every dismissal path commits exactly once. Without it
    /// `.onDisappear` after a Done-button commit would re-fire `onCommit`
    /// and the host would schedule everything twice.
    @State private var didCommit: Bool = false

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

    /// Total queued duration in minutes. Used to compute the remaining
    /// readout, the progress bar, and to gate further enqueues.
    private var queuedMinutes: Int {
        queue.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Minutes still free in the slot. Drops to zero exactly when the
    /// last queued item fills the gap, at which point we auto-commit
    /// — there's nothing more the user can do here.
    private var remainingMinutes: Int {
        max(0, slotMinutes - queuedMinutes)
    }

    /// Smallest pending candidate that hasn't been queued yet. Falls
    /// back to `Int.max` when nothing remains. Drives the auto-commit
    /// rule: if the smallest unqueued candidate no longer fits and the
    /// user isn't mid-create (draft is empty), we're done here.
    private var smallestUnqueuedFit: Int {
        let queuedIds = Set(queue.compactMap { item -> String? in
            if case let .existing(t) = item { return t.id } else { return nil }
        })
        return rankedCandidates
            .filter { !queuedIds.contains($0.id) }
            .map(\.durationMinutes)
            .min() ?? Int.max
    }

    private var slotRangeLabel: String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return "\(fmt.string(from: slotStart))\u{2013}\(fmt.string(from: slotEnd))"
    }

    private var slotDurationLabel: String {
        Self.formatDuration(slotMinutes)
    }

    private var remainingDurationLabel: String {
        Self.formatDuration(remainingMinutes)
    }

    private static func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)\u{00A0}min" }
        let h = minutes / 60
        let m = minutes % 60
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

    /// Filter-narrowed pool ranked by `TimelineSlotRanker` — applies
    /// urgency / fit / context-match / period-preference / recency
    /// in one pass. Filters compose AND with the ranker: chips
    /// narrow, the ranker orders.
    private var rankedCandidates: [BacklogTask] {
        let context = TimelineSlotRanker.SlotContext(
            start: slotStart,
            end: slotEnd,
            adjacentEvents: adjacentEvents
        )
        return TimelineSlotRanker.rank(tasks: filteredPool, slot: context)
    }

    /// True when at least one filter is engaged — drives the empty-state
    /// copy («adjust filters or type to create» vs the calm version).
    private var hasActiveFilter: Bool {
        smartFilter != nil || projectFilter != nil || colorFilter != nil
    }

    /// Every filter-matching candidate, in ranked order. The popover
    /// renders the full set inside a bounded scroll view so the user
    /// can find any task that survives the chips, not just a top-N
    /// preview — the chip row already does the narrowing job.
    private var visibleCandidates: [BacklogTask] {
        rankedCandidates
    }

    private var canCreate: Bool {
        !draftTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasQueue: Bool {
        !queue.isEmpty
    }

    /// One typed-but-not-yet-committed task in the queue. Identifiable
    /// so the chip strip can use it directly with `ForEach`. Kept as a
    /// `private struct` rather than a tuple because SwiftUI's `id:`
    /// key-path syntax doesn't accept tuple element labels.
    private struct QueuedCreateView: Identifiable {
        let stagingId: UUID
        let title: String
        let durationMinutes: Int
        let plannedStart: Date
        var id: UUID { stagingId }
    }

    /// Subset of `queue` that represents typed-but-not-yet-saved tasks.
    /// Rendered as removable chips so a user who pressed Enter on
    /// «write report 30m» can confirm the gesture took effect and
    /// pull it back out of the queue without having to commit first.
    private var queuedCreates: [QueuedCreateView] {
        var result: [QueuedCreateView] = []
        for (idx, item) in queue.enumerated() {
            if case let .create(stagingId, title, duration) = item {
                result.append(QueuedCreateView(
                    stagingId: stagingId,
                    title: title,
                    durationMinutes: duration,
                    plannedStart: plannedStart(forIndex: idx)
                ))
            }
        }
        return result
    }

    private var progressFraction: Double {
        guard slotMinutes > 0 else { return 0 }
        return min(1.0, Double(queuedMinutes) / Double(slotMinutes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            header

            // Input — autofocused on appear so the user can start typing
            // immediately. Enter enqueues a create; the field clears
            // afterwards so the user can keep typing the next item.
            TextField("Add a task or pick from below\u{2026}", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isInputFocused)
                .onSubmit(submit)
                .padding(.vertical, DS.Spacing.xxs)

            // Queued-create chips. Existing-task picks already show as
            // checked rows in the candidate list, but a typed-and-Entered
            // create has no candidate row to anchor on — without this
            // strip the user has no way to see, let alone remove, a
            // pending create. Keeps creates as first-class queue
            // citizens equal to existing picks.
            if !queuedCreates.isEmpty {
                queuedCreatesRow
            }

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

            // Candidates: every task that survives the active chips,
            // in ranked order. Bounded scroll view so a 100-task
            // backlog doesn't grow the popover off-screen — user can
            // scroll, or narrow further with the chips above.
            if visibleCandidates.isEmpty {
                Text(emptyCandidateMessage)
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.vertical, DS.Spacing.xs)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleCandidates, id: \.id) { task in
                            candidateRow(for: task)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            // Fullscreen escape — for editing tasks (rename, deadline,
            // context, reorder) that the picker deliberately doesn't
            // expose. Always available when the host wired it; the
            // copy is honest about what it does instead of pretending
            // to widen the visible set.
            if let onOpenFullscreenBacklog, !pendingPool.isEmpty {
                SkinSeparator()
                Button {
                    Haptics.tap()
                    // Commit anything queued first so the work isn't
                    // lost when the host swaps surfaces.
                    commit()
                    onOpenFullscreenBacklog()
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Text("Open in fullscreen")
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextSecondary)
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, DS.Spacing.xs)
                }
                .buttonStyle(.plain)
                .help("Open the fullscreen backlog to edit, reorder, or set deadlines")
            }
        }
        .padding(DS.Spacing.md)
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 400)
        .onAppear { isInputFocused = true }
        // Catches click-outside dismissal — the only path that doesn't
        // route through an explicit Done/Esc handler. `didCommit`
        // dedupes against the explicit paths.
        .onDisappear { commit() }
        // Esc dismiss — `keyboardShortcut(.cancelAction)` on a hidden
        // button is SwiftUI's canonical pattern for binding Esc when
        // there's no visible Cancel button. Esc commits rather than
        // discarding: a user who has queued three tasks and hits Esc
        // most likely meant «I'm done picking», not «throw it away».
        // Discarding is still possible by removing each item from the
        // queue (re-tap) before dismissal.
        .background(
            Button("", action: commit)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    // MARK: - Header
    //
    // Shows slot range, remaining time, queue count, and a thin progress
    // bar so the «filling up» metaphor is visible without reading the
    // queued items themselves. Done button appears only after the first
    // pick to avoid prompting users who only wanted to add one thing.

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(headerLabel)
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Spacing.xs)
            if hasQueue {
                Button {
                    Haptics.tap()
                    commit()
                } label: {
                    Text("Done")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                skin.accentColor.opacity(DS.Opacity.softAccent),
                                lineWidth: DS.Border.thin
                            )
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help("Schedule the queued tasks into this slot")
                .accessibilityLabel("Done — schedule \(queue.count) queued task\(queue.count == 1 ? "" : "s")")
            }
        }
        if hasQueue {
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(skin.accentColor)
                .frame(height: 2)
                .padding(.top, -DS.Spacing.xxs)
        }
    }

    /// Strip of removable chips for typed-and-Entered task drafts that
    /// don't yet exist in the backlog. Sits between the input and the
    /// candidate list so the «I just typed and pressed Enter» gesture
    /// has visible feedback and a clear undo affordance (×).
    @ViewBuilder
    private var queuedCreatesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(queuedCreates) { entry in
                    let timeStr = Self.shortTimeFormatter.string(from: entry.plannedStart)
                    Button {
                        Haptics.tap()
                        removeQueuedCreate(stagingId: entry.stagingId)
                    } label: {
                        HStack(spacing: DS.Spacing.xxs) {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption)
                                .foregroundStyle(skin.accentColor)
                            Text(entry.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(skin.resolvedTextPrimary)
                                .lineLimit(1)
                            Text("\u{2192} \(timeStr)")
                                .font(DS.Typography.machineHint)
                                .foregroundStyle(skin.resolvedTextTertiary)
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextTertiary)
                        }
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                skin.accentColor.opacity(DS.Opacity.softAccent),
                                lineWidth: DS.Border.thin
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Remove \u{201C}\(entry.title)\u{201D} from the queue")
                }
            }
            .padding(.vertical, DS.Spacing.xxs)
        }
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("H:mm")
        return f
    }()

    private func removeQueuedCreate(stagingId: UUID) {
        guard let idx = queue.firstIndex(where: { item in
            if case let .create(id, _, _) = item { return id == stagingId } else { return false }
        }) else { return }
        queue.remove(at: idx)
    }

    /// Header text: with no queue we read out the full slot range; once
    /// the user has queued something we switch to «remaining + count»
    /// because that's the live decision: «do I have room for one more?».
    private var headerLabel: String {
        if hasQueue {
            let n = queue.count
            let noun = n == 1 ? "task" : "tasks"
            if remainingMinutes <= 0 {
                return "\(n) \(noun) \u{00B7} slot full"
            }
            return "\(n) \(noun) \u{00B7} \(remainingDurationLabel) left"
        }
        return "\(slotRangeLabel) \u{00B7} \(slotDurationLabel)"
    }

    @ViewBuilder
    private func candidateRow(for task: BacklogTask) -> some View {
        let queueIdx = queue.firstIndex { item in
            if case let .existing(t) = item { return t.id == task.id } else { return false }
        }
        let plannedStart = queueIdx.map(plannedStart(forIndex:))
        let isQueued = queueIdx != nil
        // A row is enqueueable when not yet queued AND it fits the
        // current remaining window. Already-queued rows stay enabled
        // (re-tap removes them) so the user can recover from a misclick.
        let canQueue = !isQueued && task.durationMinutes <= remainingMinutes

        SlotPickerCandidateRow(
            task: task,
            isQueued: isQueued,
            plannedStart: plannedStart,
            canQueue: canQueue,
            remainingMinutes: remainingMinutes,
            durationLabel: durationLabel(task.durationMinutes),
            onTap: { toggleExisting(task) }
        )
    }

    /// Calendar time the queued item at `idx` will occupy as its start.
    /// Sum of durations before it, added to slotStart.
    private func plannedStart(forIndex idx: Int) -> Date {
        let prefixMin = queue.prefix(idx).reduce(0) { $0 + $1.durationMinutes }
        return slotStart.addingTimeInterval(TimeInterval(prefixMin * 60))
    }

    private func durationLabel(_ minutes: Int) -> String {
        // PRINCIPLES §3 — route through the shared `DS.formatMinutes`
        // helper so duration strings ride the same NBSP / unit
        // convention used everywhere else in the app.
        DS.formatMinutes(minutes)
    }

    /// Toggle a backlog task's membership in the queue. Re-tapping a
    /// queued row removes it (so misclicks are recoverable without
    /// committing first); tapping an unqueued row that fits appends it
    /// to the end. Tapping an unqueued row that *doesn't* fit is a
    /// no-op — the row already shows a «won't fit» chip explaining why.
    private func toggleExisting(_ task: BacklogTask) {
        if let idx = queue.firstIndex(where: { item in
            if case let .existing(t) = item { return t.id == task.id } else { return false }
        }) {
            Haptics.tap()
            queue.remove(at: idx)
            return
        }
        guard task.durationMinutes <= remainingMinutes else { return }
        Haptics.tap()
        queue.append(.existing(task))
        autoCommitIfFull()
    }

    /// Enter handler on the input. Parses an optional trailing duration
    /// hint (`"write report 1h"` → 60), defaults to whatever fits in the
    /// current remaining window, enqueues a `.create`, and clears the
    /// field so the user can type the next one.
    private func submit() {
        guard canCreate else { return }
        let parsed = BacklogTitleParser.parse(draftTitle)
        // Ceiling at remaining so a typed "2h" inside a 30-min hole
        // doesn't queue something that won't actually fit. Floor at 1
        // so accidentally-typed-and-immediately-submitted creates don't
        // stage zero-minute placements.
        let requested = parsed.durationMinutes ?? remainingMinutes
        let duration = max(1, min(requested, remainingMinutes))
        guard duration > 0, duration <= remainingMinutes else { return }
        Haptics.tap()
        queue.append(.create(stagingId: UUID(), title: parsed.cleaned, durationMinutes: duration))
        draftTitle = ""
        autoCommitIfFull()
    }

    /// Decide whether the picker should auto-dismiss. We close when
    /// the slot is fully booked or when no remaining backlog candidate
    /// fits AND the user isn't typing a new task. The «typing» check
    /// preserves the natural flow of «type, Enter, type, Enter» — a
    /// half-typed title shouldn't be killed by an early auto-commit.
    private func autoCommitIfFull() {
        if remainingMinutes <= 0 {
            commit()
            return
        }
        if smallestUnqueuedFit > remainingMinutes && draftTitle.isEmpty {
            commit()
        }
    }

    /// Single-shot commit — every dismissal path funnels here so the
    /// host receives one batch with one undo entry, regardless of how
    /// the user chose to leave (Done / Esc / click-outside / fullscreen).
    private func commit() {
        guard !didCommit else { return }
        didCommit = true
        onCommit(queue)
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

/// Single candidate row inside the picker. Carved into its own view so
/// each row owns its hover state — without that, a shared `@State` on
/// the parent would either highlight every row or none.
private struct SlotPickerCandidateRow: View {
    let task: BacklogTask
    /// True when this task already sits in the queue. Drives the «added»
    /// affordance and switches the tap action from enqueue to dequeue.
    let isQueued: Bool
    /// Calendar time the queued instance will start, when queued.
    /// `nil` while the row is unqueued.
    let plannedStart: Date?
    /// True when the task fits the slot's remaining time and isn't
    /// already queued. False rows render disabled with a «won't fit»
    /// chip — visual disable rather than removal so the user can see
    /// why they can't tap and decide whether to free up room.
    let canQueue: Bool
    /// Slot's current remaining minutes — used solely to disambiguate
    /// «won't fit because slot too small» from «won't fit because the
    /// queue already filled most of it» in the chip wording.
    let remainingMinutes: Int
    let durationLabel: String
    let onTap: () -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("H:mm")
        return f
    }()

    /// True when this row is interactive at all — queued rows are
    /// always tappable (to remove), unqueued rows only when they fit.
    private var isEnabled: Bool {
        isQueued || canQueue
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                if isQueued {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(skin.accentColor)
                        .accessibilityHidden(true)
                } else if BacklogLogic.isUrgent(task) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedDestructiveColor)
                        .accessibilityHidden(true)
                }

                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DS.Spacing.sm)

                if isQueued, let plannedStart {
                    // Show the planned arrival time so the user can tell at a
                    // glance where in the slot this item lands relative to
                    // the others queued before it.
                    Text("\u{2192} \(Self.timeFormatter.string(from: plannedStart))")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.accentColor)
                } else {
                    Text(durationLabel)
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }

                if !isQueued && !canQueue {
                    Text(remainingMinutes <= 0 ? "slot full" : "won't fit")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary.opacity(DS.Opacity.accentMuted))
                }
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(rowFill)
            )
            .opacity(isEnabled ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
        .help(helpText)
    }

    /// Background fill: queued > hover > clear. The queued state earns
    /// a soft accent wash so a glance down the list groups the chosen
    /// items visually, mirroring how multi-select rows work elsewhere
    /// in macOS.
    private var rowFill: Color {
        if isQueued {
            return skin.accentColor.opacity(DS.Opacity.subtleFill)
        }
        if isHovered && isEnabled {
            return skin.resolvedTextTertiary.opacity(DS.Opacity.subtleFill)
        }
        return .clear
    }

    private var titleColor: Color {
        isQueued ? skin.resolvedTextPrimary : skin.resolvedTextPrimary
    }

    private var helpText: String {
        if isQueued {
            return "Queued — tap to remove"
        }
        if !canQueue {
            return remainingMinutes <= 0
                ? "The slot is already full"
                : "Doesn't fit the remaining time"
        }
        return "Add to slot"
    }
}
