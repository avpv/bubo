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

    @State private var showingPlanDayPopover = false

    var body: some View {
        Group {
            switch resolvedState {
            case .hard:
                hardRow
            case .soft(let s):
                softRow(s)
            case .calm:
                calmRow
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

    private enum State {
        case hard
        case soft(SuggestionEngine.Suggestion)
        case calm
    }

    private var resolvedState: State {
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
            }
        )
    }

    private var hardSubtext: String? {
        let volume = DS.formatMinutes(overflowMinutes)
        switch overflowingCount {
        case 0:  return nil
        case 1:  return "1 task · \(volume) over"
        default: return "\(overflowingCount) tasks · \(volume) over"
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
            }
        )
    }

    // MARK: - Calm

    @ViewBuilder
    private var calmRow: some View {
        ContextualActionRow(
            icon: "wand.and.stars",
            verb: "Plan day\u{2026}",
            subtext: nil,
            kind: .discover,
            action: {
                await MainActor.run { showingPlanDayPopover = true }
            }
        )
        .popover(isPresented: $showingPlanDayPopover, arrowEdge: .top) {
            planDayPopover
                .frame(minWidth: 220)
                .padding(.vertical, DS.Spacing.xs)
        }
    }

    @ViewBuilder
    private var planDayPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            presetButton(icon: "wand.and.stars",         label: "Organize today",       request: .organizeDay,            successLabel: "Organized today")
            presetButton(icon: "brain.head.profile",     label: "Find 2\u{00A0}h focus", request: .findFocus(minutes: 120, period: .morning), successLabel: "Found 2\u{00A0}h focus")
            presetButton(icon: "leaf",                   label: "Low energy day",        request: .lowEnergyDay,           successLabel: "Low energy day")
            presetButton(icon: "timer",                  label: "Schedule pomodoro day", request: .pomodoroBlock,          successLabel: "Scheduled pomodoro day")
            presetButton(icon: "person.2",               label: "Batch meetings",        request: .batchMeetingsPreset,    successLabel: "Batched meetings")
            presetButton(icon: "calendar",               label: "Plan whole week",       request: .planWeek,               successLabel: "Planned the week")

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
