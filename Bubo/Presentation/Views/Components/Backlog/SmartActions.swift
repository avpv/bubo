import SwiftUI
import BuboDomain
import BuboOptimizer

/// Single contextual surface under the backlog header: one horizontal-
/// scroll chip row driven by the capacity forecast. Each forecast state
/// contributes at most one «primary» chip up front; ranked top-N calm
/// actions follow when the host wires a ranker; a trailing «Plan» chip
/// opens the ⌘K palette — the planner's single home.
///
/// - **Hard** — capacity overflow or after-hours. Prepends a destructive-
///   tinted chip («Schedule overflow» / «Pack urgent first»). Tap runs
///   the `onScheduleBacklog` / `onFocusOnDeadlines` callbacks.
/// - **Soft** — `SuggestionEngine` raised a non-overflow candidate.
///   Prepends a `sparkles`-tinted prominent chip carrying the candidate's
///   `reason`; tap runs its `request` via `onRunRequest`.
/// - **Calm** — nothing to fix. No primary chip; ranked actions (when
///   provided) plus the trailing More chip carry the row.
///
/// Subtext lives in each chip's `.help()` tooltip — trade visible
/// reasoning for a single-row footprint instead of a card.
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
    /// before committing — Birman: «the person sees the result, not
    /// the command». nil = subtext falls back to the simple overflow
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

    /// Open the command palette (global `⌘K` path, soft-suggestion
    /// fallbacks).
    let onOpenPalette: () -> Void

    /// Open the planner window (UX_WORKFLOW.md). When wired, the
    /// trailing «Plan» chip opens the window — the «one screen Today»
    /// surface — instead of the palette; ⌘K keeps the palette for
    /// power users. nil = the chip falls back to the palette.
    var onOpenPlanner: (() -> Void)? = nil

    /// Pre-ranked top-N actions from `QuickActionRanker`. When the
    /// state resolves to `.calm` and this list is non-empty, the row
    /// renders the top entries as horizontal chips (instead of the
    /// generic «Plan day…» discovery row) so the user sees concrete
    /// context-relevant verbs without a popover round-trip. Empty
    /// list = fall back to the canonical calm row.
    var rankedCalmActions: [QuickActionRanker.ScoredAction] = []

    /// Whether the trailing «Plan» chip (the planner entry point —
    /// opens the ⌘K palette) renders. Default true for the main
    /// screen; the fullscreen backlog passes false because its header
    /// already carries a persistent «Plan N» pill — two adjacent Plan
    /// verbs would read as a stutter.
    var showsPlanChip: Bool = true

    /// Optional extra chips appended to the trailing edge of the chip
    /// rail (after `planChip`). `SmartActionsBar` uses this slot to
    /// fold the capacity / free-time / backlog-entry badges into the
    /// same wrapping `ChipRow` so the single rail can wrap as one
    /// instead of two siblings competing for width in an outer HStack
    /// — the failure mode that produced chips bleeding over each
    /// other when soft-state copy was long.
    var trailing: AnyView? = nil

    @Environment(\.activeSkin) private var skin

    @State private var showingReasoningPopover = false

    var body: some View {
        Group {
            // A fresh «just applied» record beats the regular three
            // states for ~8 s — the user has just hit Run and benefits
            // from a beat of «here's what happened» before the row
            // resumes its normal duty. After the freshness window
            // expires, `chipRow` takes over again.
            if let applied = recentApplied, applied.isFresh {
                reasoningRow(applied)
            } else {
                chipRow
            }
        }
        // `DS.Animation.machineWork` — slow ease-out, no bounce. State
        // transitions here read as «machine reasoning»: forecast flips
        // from .fits to .over because the user added a long task, the
        // calm `Plan day…` row is replaced by the hard «Schedule
        // overflow» chip. Bounce would feel playful when the goal is a
        // calm reasoning beat. The hash key combines the three signals
        // that drive `resolvedState`.
        .animation(DS.Animation.machineWork, value: stateHash)
    }

    /// Single horizontal-scrolling chip row that absorbs the legacy
    /// hard/soft/calm card variants. Each state contributes at most one
    /// «primary» chip up front; ranked top-N calm actions follow when
    /// the host wires a ranker; an always-on More chip trails for the
    /// full preset popover. Subtext that used to render under the
    /// 2-line ContextualActionRow now lives in each chip's `.help()`
    /// tooltip — losing visible reasoning is the trade for keeping the
    /// surface to a single row instead of a card.
    @ViewBuilder
    private var chipRow: some View {
        ChipRow {
            // One contextual verb at a time: hard and soft states own
            // the leading slot alone; the ranker's chips surface only
            // in calm, where there is no primary verb to compete with.
            // Rendering both produced near-synonym neighbours like
            // «Schedule overflow · Schedule backlog».
            switch resolvedState {
            case .hard:
                hardChip
            case .soft(let suggestion):
                softChip(suggestion)
            case .calm:
                ForEach(rankedCalmActions, id: \.id) { entry in
                    rankedChip(for: entry)
                }
            }

            if showsPlanChip {
                planChip
            }

            if let trailing { trailing }
        }
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

    /// Hard-state primary chip — surfaces the canonical fix verb for
    /// capacity overflow / after-hours forecasts. Tinted with the skin's
    /// warning colour (orange) so the alarm reads at a glance without
    /// sliding into «something is broken» destructive red — overflow
    /// is a re-plan opportunity, not a system fault. Subtext (e.g.
    /// «4 tasks · would finish by 19:30») moves to the chip's tooltip.
    @ViewBuilder
    private var hardChip: some View {
        let useDeadlineMode = overflowHasUrgent
        let title = useDeadlineMode ? "Pack urgent first" : "Schedule overflow"
        let icon = useDeadlineMode
            ? "exclamationmark.arrow.triangle.2.circlepath"
            : "arrow.down.right.and.arrow.up.left"
        let helpText = hardSubtext.map { "\(title) — \($0)" } ?? title
        ChipButton(
            variant: .status(skin.resolvedWarningColor),
            icon: icon,
            title: title
        ) {
            Haptics.tap()
            Task {
                if useDeadlineMode { await onFocusOnDeadlines() }
                else               { await onScheduleBacklog() }
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var hardSubtext: String? {
        let volume = DS.formatMinutes(overflowMinutes)

        // When a fresh shadow proposal is available, surface its
        // projected end-time as a delta hint. The user sees what Run
        // would actually do — «would finish by 19:30, 4 tasks moved» —
        // not just «4 h over». Birman: «the person sees the result, not
        // the command». Falls back to the volume-only subtext when no
        // shadow exists yet.
        if let projection = shadowProjectionDescription {
            switch overflowingCount {
            case 0:  return projection
            case 1:  return "1\u{00A0}task · \(projection)"
            default: return "\(overflowingCount)\u{00A0}tasks · \(projection)"
            }
        }

        switch overflowingCount {
        case 0:  return nil
        case 1:  return "1\u{00A0}task · \(volume) over"
        default: return "\(overflowingCount)\u{00A0}tasks · \(volume) over"
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

    /// Transient chip that briefly replaces the regular hard/soft/calm
    /// chip row after a Run completes. Surfaces «✓ headline» as a
    /// success-tinted chip; tapping it opens the reasoning popover
    /// (the legacy «why?» trailing target merged into the chip body).
    /// Auto-fades when the underlying `AppliedRequestSummary.isFresh`
    /// flips to false. Now wrapped in `ChipRow` so the layout stays
    /// consistent with every other state — one row, no card.
    ///
    /// Birman: «the optimizer is not magic — it is an explicit rule».
    /// Showing the intents back to the user closes the loop between
    /// «I hit Run» and «I see what the machine actually did».
    @ViewBuilder
    private func reasoningRow(_ applied: AppliedRequestSummary) -> some View {
        ChipRow {
            ChipButton(
                variant: .status(skin.resolvedSuccessColor),
                icon: "checkmark.circle.fill",
                title: applied.headline
            ) {
                Haptics.tap()
                showingReasoningPopover = true
            }
            .help("Show which optimizer intents drove this run")
            .popover(isPresented: $showingReasoningPopover, arrowEdge: .top) {
                reasoningPopover(applied)
                    .frame(minWidth: 220, idealWidth: 260)
                    .padding(.vertical, DS.Spacing.sm)
            }

            if let trailing { trailing }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func reasoningPopover(_ applied: AppliedRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Applied")
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
                .padding(.vertical, DS.Spacing.hairline)
            }

            if descriptions.count > 6 {
                Text("\u{2026} and \(descriptions.count - 6) more")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.xxs)
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

    /// Soft-state primary chip — sparkles glyph plus the underlying
    /// `OptimizationRequest`'s short name as the chip title (e.g.
    /// «Schedule tasks», «Plan week», «Find focus»). Falls back to the
    /// generic «Run suggestion» verb when the request is unnamed. The
    /// long `suggestion.reason` and the `softSubtext` projection
    /// (e.g. «would finish by 19:30») move to the tooltip so the chip
    /// stays narrow and the surface stays a single row.
    @ViewBuilder
    private func softChip(_ suggestion: SuggestionEngine.Suggestion) -> some View {
        let title = suggestion.request.name ?? "Run suggestion"
        let helpText = softHelpText(suggestion)
        ChipButton(
            variant: .prominent,
            icon: "sparkles",
            title: title
        ) {
            Haptics.tap()
            Task { await onRunRequest(suggestion.request, suggestion.reason) }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    /// Compose the soft-chip tooltip — full reason joined with the
    /// projection subtext when both are non-empty. Picks whichever
    /// pieces are present; «Run suggestion» is the chip's already-
    /// visible fallback so the helpText stays informative.
    private func softHelpText(_ suggestion: SuggestionEngine.Suggestion) -> String {
        let pieces = [suggestion.reason, softSubtext(suggestion)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? "Run suggestion" : pieces.joined(separator: " \u{2014} ")
    }

    /// One-line preview of what Run will do for a soft suggestion.
    /// Prefers the shadow proposal's projected end-time when available
    /// (matches the hard state's "would finish by 19:30" idiom), then
    /// falls back to a comma-list of human-readable intents derived
    /// from the same `intentDescription(_:)` table the reasoning
    /// popover uses. Returns nil if there's nothing meaningful to add.
    private func softSubtext(_ suggestion: SuggestionEngine.Suggestion) -> String? {
        if let projection = shadowProjectionDescription {
            return projection
        }
        let descriptions = suggestion.request.intents
            .map(intentDescription)
            .filter { !$0.isEmpty }
        guard !descriptions.isEmpty else { return nil }
        // Cap at three so the subtext never wraps. Most suggestions
        // produce 2-4 user-visible intents; the cap protects against
        // composer-heavy days where five layers stack.
        let visible = Array(descriptions.prefix(3))
        let suffix = descriptions.count > visible.count ? " · \u{2026}" : ""
        return visible.joined(separator: " · ") + suffix
    }

    // MARK: - Calm

    // Calm-state rendering is part of the unified `chipRow`. When the
    // ranker isn't wired and there's nothing to suggest, the row
    // collapses to just the trailing `planChip` — the planner's front
    // door (opens the ⌘K palette). The legacy `calmRow` view-builder
    // was deleted; preview hosts that used to exercise it now go
    // through `chipRow` like every other state.

    @ViewBuilder
    private func rankedChip(for entry: QuickActionRanker.ScoredAction) -> some View {
        ChipButton(
            variant: .prominent,
            icon: entry.action.icon,
            title: entry.action.label
        ) {
            Haptics.tap()
            Task { await onRunRequest(entry.action.request, entry.action.label) }
        }
        .help(entry.reason.isEmpty
              ? "Run «\(entry.action.label)»"
              : "\(entry.action.label) · \(entry.reason)")
        .accessibilityLabel(entry.reason.isEmpty
            ? entry.action.label
            : "\(entry.action.label). \(entry.reason).")
    }

    /// «Plan» — the planner's front door. Opens the planner window when
    /// the host wires it (UX_WORKFLOW.md: planning is direct
    /// manipulation on one screen), otherwise falls back to the ⌘K
    /// palette.
    @ViewBuilder
    private var planChip: some View {
        ChipButton(
            variant: .quiet,
            icon: "rectangle.split.2x1",
            title: "Plan"
        ) {
            Haptics.tap()
            (onOpenPlanner ?? onOpenPalette)()
        }
        .help(onOpenPlanner != nil
              ? "Open the planner window — tasks beside your day (\u{2318}P)"
              : "Open the planner — presets, focus blocks, week planning (\u{2318}K)")
        .accessibilityLabel("Open the planner")
    }
}
