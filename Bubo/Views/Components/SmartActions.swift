import SwiftUI

/// Single contextual surface that absorbs four legacy entry points to the
/// optimizer (`SmartBanner`, `SpillOverMarker`, `QuickActions` chip, and
/// `PlanDayMenu`) into one row that lives directly under the backlog
/// header. Adapts to one of three states:
///
/// - **Hard** — capacity overflow or after-hours. Renders the canonical fix
///   verb («Schedule overflow into free slots»). Tap = run via the same
///   `onScheduleBacklog` / `onFocusOnDeadlines` callbacks the old marker
///   used.
/// - **Soft** — `SuggestionEngine` raised a non-overflow candidate. Renders
///   the candidate's `reason` and runs its `request` via `onRunRequest`.
/// - **Calm** — nothing to fix. Renders a discovery row («Plan day…») with
///   a `⌘K` hint; tapping it opens a popover of six outcome-named presets,
///   the same set `PlanDayMenu` used to expose.
///
/// Birman: «прямое действие на месте проблемы»; диагноз и лечение
/// рядом, один канал, никаких параллельных кнопок.
///
/// The host is responsible for placement (just under the backlog header)
/// and for any padding required to align with the card's vertical axis.
struct SmartActions: View {

    /// Forecast computed by `BacklogLogic.capacityForecast` — drives the
    /// hard/soft/calm choice. Hard wins over Soft when both apply.
    let forecast: BacklogLogic.CapacityForecast

    /// Number of overflowing tasks (when forecast is `.over` / `.afterHours`).
    /// Used in subtext copy («4 tasks · 4 h overflow»).
    let overflowingCount: Int

    /// Total minutes spilling past today's working window. Used in subtext
    /// copy when forecast is over/afterHours.
    let overflowMinutes: Int

    /// Whether the overflow set contains an urgent (≤2 days) deadline. When
    /// true, a `Pack urgent first` row appears as an alternative; when false
    /// the urgent path is hidden entirely.
    let overflowHasUrgent: Bool

    /// Soft suggestion from `SuggestionEngine`. Surfaced only in calm-fits
    /// state — hard problems always take priority. Pass `nil` when nothing
    /// is suggested.
    let suggestion: SuggestionEngine.Suggestion?

    /// Optional «if you Run now this is what'd happen» preview from the
    /// background `OptimizerService.shadowProposal`. When set and recent,
    /// the Hard row's subtext picks up a delta hint («would finish by
    /// 19:30 · 4 tasks moved»). Lets the user see the outcome of a Run
    /// before committing — Birman: «человек видит результат, не
    /// команду». nil = subtext falls back to the simple overflow
    /// volume («4 tasks · 4 h 32 min over»).
    let shadowProposal: ScheduleScenario?

    /// Lightweight summary of the most recently applied optimization,
    /// kept fresh for ~8 s by `OptimizerService.lastAppliedRequest`. When
    /// set and `isFresh`, the row swaps from its three regular states
    /// (hard / soft / calm) to a transient «Done · why?» reasoning hint.
    /// Pass `nil` to suppress entirely.
    let recentApplied: AppliedRequestSummary?

    /// Schedule the overflow set onto the calendar via the optimizer.
    /// Mirrors the old `SpillOverMarker.onSchedule` signature.
    let onScheduleBacklog: () async -> Void

    /// Run the optimizer with deadline priority — surfaced only when the
    /// overflow set contains urgent items. Mirrors the old `onFocusOnDeadlines`.
    let onFocusOnDeadlines: () async -> Void

    /// Execute an arbitrary request (for soft-suggestion Run and for
    /// `Plan day…` presets). Same async helper `MenuBarView.runQuickAction`
    /// already provides — toast + undo come for free.
    let onRunRequest: (OptimizationRequest, String) async -> Void

    /// Open the command palette (`More…` route from the calm popover, plus
    /// the global `⌘K` shortcut path).
    let onOpenPalette: () -> Void

    /// Cycle the applied scenario to a specific index in the existing
    /// `scenarios` array. Wired from `MenuBarView` to
    /// `OptimizerService.switchToAppliedScenario(at:)`. nil = cycling
    /// is disabled (preview surfaces without an optimizer service).
    var onSwitchScenario: ((Int) -> Void)? = nil

    /// Bulk-lock today's events — adds every event currently rendered
    /// on today's section to `OptimizerService.lockedEventIds`. Useful
    /// before running the optimizer to ensure nothing already on the
    /// calendar moves; the GA only places overflow / new tasks. nil =
    /// the quick-action is hidden from the calm-state popover.
    var onLockTodaysEvents: (() -> Void)? = nil

    /// Render the contextual rows in single-line compact form. Used by
    /// the inline backlog where vertical space is at a premium and the
    /// list itself needs every pixel below the header. Default `false`
    /// keeps the canonical 2-line stacked layout for fullscreen.
    var compact: Bool = false

    /// Pre-ranked top-N actions from `QuickActionRanker`. When the
    /// state resolves to `.calm` and this list is non-empty, the row
    /// renders the top entries as horizontal chips (instead of the
    /// generic «Plan day…» discovery row) so the user sees concrete
    /// context-relevant verbs without a popover round-trip. Empty
    /// list = fall back to the canonical calm row.
    var rankedCalmActions: [QuickActionRanker.ScoredAction] = []

    @Environment(\.activeSkin) private var skin

    @State private var showingPlanDayPopover = false
    @State private var showingReasoningPopover = false

    var body: some View {
        Group {
            // A fresh «just applied» record beats the regular three
            // states for ~8 s — the user has just hit Run and benefits
            // from a beat of «here's what happened» before the row
            // resumes its normal duty. After the freshness window
            // expires, `resolvedState` takes over again.
            if let applied = recentApplied, applied.isFresh {
                reasoningRow(applied)
            } else {
                switch resolvedState {
                case .hard:
                    hardRow
                case .soft(let s):
                    softRow(s)
                case .calm:
                    calmRow
                }
            }
        }
        // `DS.Animation.machineWork` — slow ease-out, no bounce. State
        // transitions here read as «machine reasoning»: forecast flips
        // from .fits to .over because the user added a long task, the
        // calm `Plan day…` row is replaced by the hard «Schedule
        // overflow» row. Bounce would feel playful when the goal is a
        // calm reasoning beat. The hash key combines the three signals
        // that drive `resolvedState`.
        .animation(DS.Animation.machineWork, value: stateHash)
    }

    /// Stable hash that ticks whenever `resolvedState` would change. Used
    /// as the `value:` for `.animation(machineWork, ...)`. Hashing
    /// `forecast` is enough for hard/calm transitions; we add the
    /// suggestion's name (when present) so soft → soft swaps animate.
    private var stateHash: Int {
        var hasher = Hasher()
        switch forecast {
        case .fits:           hasher.combine(0)
        case .over:           hasher.combine(1)
        case .afterHours:     hasher.combine(2)
        }
        hasher.combine(suggestion?.reason ?? "")
        return hasher.finalize()
    }

    // MARK: - State resolution

    private enum Resolution {
        case hard
        case soft(SuggestionEngine.Suggestion)
        case calm
    }

    private var resolvedState: Resolution {
        switch forecast {
        case .over, .afterHours:
            return .hard
        case .fits:
            if let suggestion { return .soft(suggestion) }
            return .calm
        }
    }

    // MARK: - Hard

    @ViewBuilder
    private var hardRow: some View {
        // Pick `deadlineMode` when there's an urgent overflow item — pack
        // those first instead of round-robin scheduling. Otherwise fall
        // back to plain `scheduleBacklog`.
        let useDeadlineMode = overflowHasUrgent
        ContextualActionRow(
            icon: useDeadlineMode ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.right.and.arrow.up.left",
            verb: useDeadlineMode ? "Pack urgent tasks first" : "Schedule overflow into free slots",
            subtext: hardSubtext,
            kind: .run,
            action: {
                if useDeadlineMode { await onFocusOnDeadlines() }
                else               { await onScheduleBacklog() }
            },
            compact: compact
        )
    }

    private var hardSubtext: String? {
        let volume = DS.formatMinutes(overflowMinutes)

        // When a fresh shadow proposal is available, surface its
        // projected end-time as a delta hint. The user sees what Run
        // would actually do — «would finish by 19:30, 4 tasks moved» —
        // not just «4 h over». Birman: «человек видит результат, не
        // команду». Falls back to the volume-only subtext when no
        // shadow exists yet.
        if let projection = shadowProjectionDescription {
            switch overflowingCount {
            case 0:  return projection
            case 1:  return "1 task · \(projection)"
            default: return "\(overflowingCount) tasks · \(projection)"
            }
        }

        switch overflowingCount {
        case 0:  return nil
        case 1:  return "1 task · \(volume) over"
        default: return "\(overflowingCount) tasks · \(volume) over"
        }
    }

    /// Latest end-time across the shadow scenario's active genes,
    /// formatted as «would finish by 19:30». Returns nil when no
    /// shadow proposal is cached or the scenario carries no genes.
    private var shadowProjectionDescription: String? {
        guard let scenario = shadowProposal else { return nil }
        let endTimes = scenario.activeGenes.map(\.endTime)
        guard let latest = endTimes.max() else { return nil }
        return "would finish by \(Self.shortTime.string(from: latest))"
    }

    private static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    // MARK: - Reasoning surface (Done · why?)

    /// Transient row that briefly replaces the regular hard/soft/calm
    /// states after a Run completes. Surfaces «Done · headline» as the
    /// primary verb (no Run button), with a «why?» tap-target on the
    /// trailing slot that opens a popover listing the human-readable
    /// intent breakdown. Auto-fades when the underlying
    /// `AppliedRequestSummary.isFresh` flips to false.
    ///
    /// Birman: «оптимизатор не магия — он явное правило». Showing the
    /// intents back to the user closes the loop between «I hit Run»
    /// and «I see what the machine actually did».
    @ViewBuilder
    private func reasoningRow(_ applied: AppliedRequestSummary) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
                .frame(width: DS.Size.iconSmall, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(applied.headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DS.Spacing.sm)

            Button {
                Haptics.tap()
                showingReasoningPopover = true
            } label: {
                Text("why?")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            .help("Show which optimizer intents drove this run")
            .popover(isPresented: $showingReasoningPopover, arrowEdge: .trailing) {
                reasoningPopover(applied)
                    .frame(minWidth: 220, idealWidth: 260)
                    .padding(.vertical, DS.Spacing.sm)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .transition(.opacity)
    }

    @ViewBuilder
    private func reasoningPopover(_ applied: AppliedRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            // `DS.Typography.label` — uppercase-tracked caption2.medium,
            // the canonical voice for section labels. First adopter; will
            // also fit the upcoming per-day section labels and filter chip
            // groupings.
            Text("Applied")
                .font(DS.Typography.label(skin: skin))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(skin.resolvedTextTertiary)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.xxs)

            // Render the request's intents as human-readable bullets.
            // `intentDescription(_:)` strips `case` syntax and returns
            // a calm verb-form; technical/parameter intents
            // (`.speed`, `.scenarios`, `.autoApply`, `.notify`) return
            // an empty string and are filtered out — those are tuning
            // knobs the user shouldn't have to read about. Limited to
            // first 6 of the remaining set to keep the popover glanceable.
            let descriptions = applied.request.intents
                .map(intentDescription)
                .filter { !$0.isEmpty }
            let visible = Array(descriptions.prefix(6))
            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(skin.accentColor)
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextPrimary)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, 1)
            }

            if descriptions.count > 6 {
                Text("\u{2026} and \(descriptions.count - 6) more")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.xxs)
            }

            // Scenario picker — surfaced when the optimizer returned
            // more than one scenario. Each dot is a button that swaps
            // the active genes for the corresponding scenario via
            // `onSwitchScenario`. Wired through `OptimizerService`'s
            // `switchToAppliedScenario(at:)` which handles the
            // rollback + reapply atomically (events removed, undo
            // snapshot rebased, scenarios array preserved).
            if applied.scenarioCount > 1 {
                Divider()
                    .padding(.top, DS.Spacing.xs)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(0..<applied.scenarioCount, id: \.self) { idx in
                        Button {
                            guard idx != applied.appliedScenarioIndex else { return }
                            Haptics.tap()
                            onSwitchScenario?(idx)
                        } label: {
                            Circle()
                                .fill(idx == applied.appliedScenarioIndex
                                      ? skin.accentColor
                                      : skin.resolvedTextTertiary.opacity(0.4))
                                .frame(width: 8, height: 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(idx == applied.appliedScenarioIndex
                              ? "Currently applied"
                              : "Switch to scenario \(idx + 1)")
                        .disabled(onSwitchScenario == nil)
                    }
                    Spacer(minLength: DS.Spacing.sm)
                    Text("Scenario \(applied.appliedScenarioIndex + 1) of \(applied.scenarioCount)")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.xs)
            }
        }
    }

    /// Coarse human-readable rendering of a `ScheduleIntent`. Doesn't
    /// have to enumerate every case — the popover is informative, not
    /// exhaustive. Unknown cases fall back to a sanitised reflection
    /// of the case name so we never silently drop signals.
    private func intentDescription(_ intent: ScheduleIntent) -> String {
        switch intent {
        case .findSlotsForBacklog, .includeBacklog, .includeBacklogTasks:
            return "Schedule backlog into free slots"
        case .prioritizeDeadlines:
            return "Prioritise tasks with deadlines"
        case .prioritizeFocus:
            return "Pack focus work first"
        case .minimizeContextSwitching:
            return "Minimise context switching"
        case .groupByProject:
            return "Group tasks by project"
        case .batchMeetings:
            return "Batch meetings into a window"
        case .lowEnergy:
            return "Treat today as low-energy"
        case .protectLunch:
            return "Protect the lunch slot"
        case .breakEvery:
            return "Insert breaks between blocks"
        case .focusBlock:
            return "Carve out a focus block"
        case .pomodoroSession:
            return "Stack tasks into a pomodoro"
        case .stability:
            return "Keep existing events stable"
        case .keepFixed:
            return "Pin selected events"
        case .speed, .scenarios, .autoApply, .notify:
            return ""
        default:
            // Strip Swift's `caseName(args)` reflection to a flat verb.
            let raw = String(describing: intent)
            let firstWord = raw.split(separator: "(").first.map(String.init) ?? raw
            return firstWord
                .replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
                .capitalized
        }
    }

    // MARK: - Soft

    @ViewBuilder
    private func softRow(_ suggestion: SuggestionEngine.Suggestion) -> some View {
        ContextualActionRow(
            icon: "lightbulb.max.fill",
            verb: suggestion.reason,
            subtext: nil,
            kind: .run,
            action: {
                await onRunRequest(suggestion.request, suggestion.reason)
            },
            compact: compact
        )
    }

    // MARK: - Calm

    @ViewBuilder
    private var calmRow: some View {
        if rankedCalmActions.isEmpty {
            // Fallback: classic «Plan day…» discovery row when the
            // host hasn't wired the ranker (preview surfaces, etc.).
            ContextualActionRow(
                icon: "wand.and.stars",
                verb: "Plan day\u{2026}",
                subtext: nil,
                kind: .discover,
                action: {
                    await MainActor.run { showingPlanDayPopover = true }
                },
                compact: compact
            )
            .popover(isPresented: $showingPlanDayPopover, arrowEdge: .top) {
                planDayPopover
                    .frame(minWidth: 220)
                    .padding(.vertical, DS.Spacing.xs)
            }
        } else {
            // Ranked-chip strip: top-N concrete verbs from
            // `QuickActionRanker`, plus a trailing «More…» chip that
            // still opens the full 12-preset popover. Birman:
            // машина уже знает что предложить — выводи это сразу,
            // не за второй клик.
            HStack(spacing: DS.Spacing.xs) {
                ForEach(rankedCalmActions, id: \.id) { entry in
                    rankedChip(for: entry)
                }
                moreChip
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .popover(isPresented: $showingPlanDayPopover, arrowEdge: .top) {
                planDayPopover
                    .frame(minWidth: 220)
                    .padding(.vertical, DS.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private func rankedChip(for entry: QuickActionRanker.ScoredAction) -> some View {
        Button {
            Haptics.tap()
            Task { await onRunRequest(entry.action.request, entry.action.label) }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: entry.action.icon)
                    .font(.caption)
                Text(entry.action.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
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
        .help(entry.reason.isEmpty
              ? "Run «\(entry.action.label)»"
              : "\(entry.action.label) · \(entry.reason)")
        .accessibilityLabel(entry.reason.isEmpty
            ? entry.action.label
            : "\(entry.action.label). \(entry.reason).")
    }

    @ViewBuilder
    private var moreChip: some View {
        Button {
            Haptics.tap()
            showingPlanDayPopover = true
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: "ellipsis")
                    .font(.caption)
                Text("More")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(skin.resolvedTextSecondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.accentColor.opacity(DS.Opacity.borderIdle),
                    lineWidth: DS.Border.thin
                )
            )
        }
        .buttonStyle(.plain)
        .help("Open the full preset catalog")
    }

    @ViewBuilder
    private var planDayPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Full preset catalog — six categories from
            // `IntentPresets.allCategories`, each rendered as a
            // group of rows separated by a thin Divider. Was a flat
            // 6-item list before; the new shape exposes every named
            // preset (12) so the user has a single place to reach
            // them without bouncing into ⌘K. ⌘K still escape-hatches
            // to arbitrary intent composition (238 cases).
            ForEach(Array(Self.presetGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider()
                        .padding(.vertical, DS.Spacing.xxs)
                }
                ForEach(group, id: \.label) { entry in
                    presetButton(
                        icon: entry.icon,
                        label: entry.label,
                        request: entry.request,
                        successLabel: entry.successLabel
                    )
                }
            }

            // Bulk-lock today's events. Per-event constraint, not a
            // scheduling recipe — kept below the recipes with its
            // own divider. Hidden when the host doesn't wire it
            // (preview surfaces).
            if let lockHandler = onLockTodaysEvents {
                Divider()
                    .padding(.vertical, DS.Spacing.xxs)
                Button {
                    Haptics.tap()
                    showingPlanDayPopover = false
                    lockHandler()
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "lock.fill")
                            .frame(width: DS.Size.iconSmall)
                        Text("Lock today's events")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pin every event already on today's schedule so the optimizer doesn't move them")
            }

            Divider()
                .padding(.vertical, DS.Spacing.xxs)

            Button {
                Haptics.tap()
                showingPlanDayPopover = false
                onOpenPalette()
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: DS.Size.iconSmall)
                    Text("More\u{2026}")
                    Spacer(minLength: 0)
                    // Shared «machine speech» voice — same hint shape as the
                    // calm-state row's trailing slot, so the keyboard cue
                    // reads consistently across both surfaces.
                    Text("\u{2318}K")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Compact metadata for one row in the Plan day popover.
    private struct PresetEntry {
        let icon: String
        let label: String
        let request: OptimizationRequest
        let successLabel: String
    }

    /// Six categories × N presets — surfaces every entry in
    /// `IntentPresets.allCategories` plus the parameterised variants
    /// SmartActions historically exposed («Find 2 h focus» / «Find
    /// 3 h focus»). Static so the array is built once at type load,
    /// not per-render.
    private static let presetGroups: [[PresetEntry]] = [
        // Planning
        [
            PresetEntry(icon: "wand.and.stars",      label: "Organize today",         request: .organizeDay,                                       successLabel: "Organized today"),
            PresetEntry(icon: "calendar",            label: "Plan week",              request: .planWeek,                                          successLabel: "Planned the week"),
            PresetEntry(icon: "calendar.badge.plus", label: "Schedule tasks",         request: .scheduleBacklog,                                   successLabel: "Scheduled tasks"),
        ],
        // Focus
        [
            PresetEntry(icon: "brain.head.profile",  label: "Find 2\u{00A0}h focus",  request: .findFocus(minutes: 120, period: .morning),         successLabel: "Found 2\u{00A0}h focus"),
            PresetEntry(icon: "scope",               label: "Find 3\u{00A0}h focus",  request: .findFocus(minutes: 180, period: .morning),         successLabel: "Found 3\u{00A0}h focus"),
            PresetEntry(icon: "timer",               label: "Pomodoro session",       request: .pomodoroBlock,                                     successLabel: "Scheduled pomodoro day"),
            PresetEntry(icon: "flame",               label: "Focus burst",            request: .focusBurstBlock(),                                 successLabel: "Scheduled focus burst"),
        ],
        // Deadlines
        [
            PresetEntry(icon: "exclamationmark.circle", label: "Deadline mode",       request: .deadlineMode,                                      successLabel: "Focused on deadlines"),
        ],
        // Meetings
        [
            PresetEntry(icon: "person.2",            label: "Batch meetings",         request: .batchMeetingsPreset,                               successLabel: "Batched meetings"),
            PresetEntry(icon: "arrow.left.and.right",label: "Buffer between meetings",request: .meetingBuffer(),                                   successLabel: "Added meeting buffers"),
        ],
        // Energy
        [
            PresetEntry(icon: "leaf",                label: "Low energy day",         request: .lowEnergyDay,                                      successLabel: "Low energy day"),
        ],
        // Adjustments
        [
            PresetEntry(icon: "moon.stars",          label: "Late start",             request: .lateStart(),                                       successLabel: "Late start scheduled"),
            PresetEntry(icon: "clock.arrow.circlepath", label: "Short day",           request: .shortDay(),                                        successLabel: "Short day scheduled"),
        ],
    ]

    @ViewBuilder
    private func presetButton(icon: String, label: String, request: OptimizationRequest, successLabel: String) -> some View {
        Button {
            Haptics.tap()
            showingPlanDayPopover = false
            Task { await onRunRequest(request, successLabel) }
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: icon)
                    .frame(width: DS.Size.iconSmall)
                Text(label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
