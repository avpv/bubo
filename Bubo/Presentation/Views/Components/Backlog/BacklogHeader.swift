import SwiftUI
import BuboDomain

// MARK: - Mode

/// Reading the mode in which `BacklogHeader` is rendered. The inline card
/// and the fullscreen popover share a single component, but differ in two
/// details: whether the list can be collapsed (chevron + count → button vs
/// plain text) and whether there is an «open fullscreen» button. Everything
/// else — ring, capacity verdict, smart-sort toggle, urgent pill — is the
/// same in both modes.
enum BacklogHeaderMode {
    /// Inline inside the Tasks card on the main popover. The header can
    /// collapse/expand (chevron + toggle button), and offers an
    /// «open fullscreen» button.
    case inline(
        expansion: Binding<TaskListExpansion>,
        onEnterFullscreen: (() -> Void)?
    )
    /// Fullscreen backlog card filling the popover. No chevron — there's
    /// nowhere to collapse: this is already the full card.
    case fullscreen
}

// MARK: - Header

/// Mode-aware header for both backlog presentations: inline (collapsible
/// card on the main popover) and fullscreen (whole-popover card).
///
/// Previously each mode kept its own header HStack as a private
/// `@ViewBuilder`, and every edit («tasks» suffix on count, urgent pill on
/// its own row, smart-sort always visible) had to be mirrored across two
/// files — and a couple of times they nearly drifted apart on tooltips and
/// accessibility labels. Now both modes assemble the header through this
/// component: the variable parts are the `Mode` enum, the common skeleton
/// (ring → count → sort → fullscreen-btn, and verdict + urgent below it)
/// is described here and must be changed in exactly one place.
///
/// Inside:
///   - Header HStack: ring, count, eta, sort, spacer, [fullscreen-btn for inline]
///   - Capacity verdict on a separate line below the header (in both modes)
///   - Urgent pill on a separate line (when `urgentCount > 0`, in both modes)
///
/// Inline mode threads `expansion` and `onEnterFullscreen` through
/// `Mode.inline`. Smart-sort and urgent toggles in this mode can
/// «pop open» a collapsed list (`.collapsed → .compact`); otherwise the
/// filtering would hide behind the collapsed header.
struct BacklogHeader<EtaContent: View>: View {
    let mode: BacklogHeaderMode
    let totalCount: Int
    let urgentCount: Int
    let pendingMinutes: Int
    let remainingWorkdayMinutes: Int
    let optimizerService: OptimizerService
    let capacityRingTooltip: String

    @Binding var useSmartSort: Bool

    /// Optional one-tap «Plan unscheduled tasks» action — when set and
    /// `pendingUnscheduledCount > 0`, the header renders a calm pill
    /// next to the sort toggle. Lets the user kick off the same
    /// optimizer run that SmartActions exposes contextually, but as a
    /// persistent, predictable verb attached to the header. Closes the
    /// «I don't know how to plan optimally» complaint where the only
    /// entry to bulk-scheduling was a contextual SmartAction that may
    /// be in calm/soft state with the verb hidden.
    var onPlanBacklog: (() async -> Void)? = nil

    /// Number of pending tasks the «Plan» button would target. Drives
    /// the badge inside the pill («Plan 4») and gates visibility — the
    /// pill hides when there's nothing to plan so the header stays
    /// calm on already-scheduled days.
    var pendingUnscheduledCount: Int = 0

    @ViewBuilder let etaChip: () -> EtaContent

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ReminderSettings.self) private var settings

    var body: some View {
        // Apple-philosophy split: title block on the leading side, a
        // dedicated toolbar on the trailing side. The previous version
        // crammed 7-8 controls (ring, count, ETA, sort, plan, project,
        // fullscreen) into one HStack masquerading as a header — that's
        // a toolbar pretending to be a title. Apple separates the two:
        // the title block tells the user *what* they're looking at, the
        // toolbar offers *what they can do with it*.
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                titleBlock
                Spacer(minLength: 0)
                toolbar
            }
            if totalCount > 0 {
                BacklogCapacityLabel(
                    pendingMinutes: pendingMinutes,
                    overflowingCount: 0,
                    optimizerService: optimizerService
                )
            }
        }
        // No horizontal padding of its own: the host already places the
        // header on the screen's `contentMargin` axis. The extra sm
        // here pushed the ring/count to a 24 pt axis while the popover
        // title above sat at 16 — one of four competing left edges the
        // screen used to have (DS: «all content hangs on one axis»).
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: Title block (eyebrow + ring + count)

    /// Eyebrow + title — Apple's section-header vocabulary. Small-caps
    /// «BACKLOG» eyebrow over the count + capacity ring row.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Eyebrow only in inline mode — fullscreen already carries a
            // «Backlog» title in its `PopoverHeader`, and repeating the
            // word a few points below it read as a stutter.
            if case .inline = mode {
                SectionLabel(text: "Backlog")
            }

            HStack(spacing: DS.Spacing.sm) {
                if totalCount > 0 {
                    BacklogCapacityRing(
                        pendingMinutes: pendingMinutes,
                        remainingWorkdayMinutes: remainingWorkdayMinutes,
                        optimizerService: optimizerService
                    )
                    .help(capacityRingTooltip)
                }
                countLabel
                etaChip()
            }
        }
    }

    // MARK: Toolbar (right-aligned commands)

    /// Apple-philosophy toolbar: a compact row of plain SF-Symbol
    /// buttons on the trailing edge, no circle backgrounds, no
    /// fill+stroke pills. The smart-sort active state and the plan
    /// affordance get a single subtle tint — no double surfaces.
    private var toolbar: some View {
        HStack(spacing: DS.Spacing.xs) {
            if totalCount > 1 {
                smartSortButton
            }
            if onPlanBacklog != nil, pendingUnscheduledCount > 0 {
                planButton
            }
            BacklogProjectPicker(
                settings: settings,
                remindersService: AppleRemindersService.shared
            )
            if case .inline(_, let onEnterFullscreen) = mode,
               totalCount > 0,
               let action = onEnterFullscreen {
                fullscreenButton(action: action)
            }
        }
    }


    // MARK: Inline expansion side-effect

    /// Engaging smart-sort or urgent-only filter while the inline list is
    /// collapsed would hide the reordered/filtered set behind a closed
    /// header — open to `.compact` so the new state is immediately visible.
    /// No-op in fullscreen (no collapsed state) and when the toggle is
    /// being turned off (no need to spring the list open on disengage).
    private func expandIfCollapsed(whenEnabled enabled: Bool) {
        guard enabled,
              case .inline(let expansion, _) = mode,
              expansion.wrappedValue == .collapsed else { return }
        expansion.wrappedValue = .compact
    }

    // MARK: Count

    /// Inline mode wraps the count in a button with a chevron
    /// (collapsed/compact toggle); fullscreen is just a number (the card
    /// is already expanded across the whole popover, nothing to chevron).
    @ViewBuilder
    private var countLabel: some View {
        let label = "\(totalCount)\u{00A0}task\(totalCount == 1 ? "" : "s")"
        switch mode {
        case .inline(let expansion, _):
            Button {
                // `.levelChange` for the chevron — collapsed/compact is a
                // discrete card-state change.
                Haptics.impact()
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    expansion.wrappedValue = expansion.wrappedValue.next
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: expansion.wrappedValue.iconName)
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.symbolEffect(.replace))
                    countText(label)
                }
            }
            .buttonStyle(.plain)
            .help("\(label) \u{00B7} \(expansion.wrappedValue.accessibilityHint.lowercased())")
            .accessibilityLabel(label)
            .accessibilityHint(expansion.wrappedValue.accessibilityHint)
        case .fullscreen:
            countText(label)
                .help("\(label) in backlog")
                .accessibilityLabel(label)
        }
    }

    private func countText(_ label: String) -> some View {
        Text(label)
            // `DS.Typography.metric` — single voice for inline numeric
            // facts in the header. Matches `Done by HH:MM` digits in
            // `BacklogCapacityLabel` so all numbers read as one rhythm.
            .font(DS.Typography.metric(skin: skin))
            .foregroundStyle(skin.resolvedTextPrimary)
            .contentTransition(.numericText())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Smart-sort

    private var smartSortButton: some View {
        // Apple-toolbar idiom: plain tinted glyph, no circle background.
        // Active vs inactive expressed by colour alone (accent vs
        // secondary) — Mail / Reminders use the same pattern for
        // toolbar toggles. The previous filled-circle background put
        // a second surface around the glyph; one surface here.
        Button {
            Haptics.impact()
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                useSmartSort.toggle()
                expandIfCollapsed(whenEnabled: useSmartSort)
            }
        } label: {
            Image(systemName: useSmartSort ? "wand.and.stars" : "arrow.up.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(useSmartSort ? skin.accentColor : skin.resolvedTextSecondary)
                .frame(width: DS.Size.iconLarge, height: DS.Size.iconLarge)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        // Capacity sections (FITS / spill-over) compose on top of sort,
        // so when smart-sort is active each group reads priority-first
        // within itself. Tooltip names that interaction.
        .help(useSmartSort
            ? "Sorted by priority within each capacity group. Tap to show in user order."
            : "Smart sort by deadline + priority")
        .accessibilityLabel(useSmartSort
            ? "Smart sort on, ordered by priority within capacity groups — tap for user order"
            : "Smart sort off — tap to enable")
    }

    // MARK: Plan button

    /// One-tap entry to bulk-schedule the unscheduled set. Renders as
    /// a calm accent pill with the pending count baked into the label
    /// — keeps the verb visible at all times instead of hiding behind
    /// the SmartActions state machine. Birman: «commands live next to
    /// the diagnosis» — the pending count is right there in the header,
    /// and so is the action that resolves it.
    @State private var isPlanning: Bool = false

    @ViewBuilder
    private var planButton: some View {
        if let onPlanBacklog {
            Button {
                guard !isPlanning else { return }
                Haptics.tap()
                isPlanning = true
                Task {
                    await onPlanBacklog()
                    isPlanning = false
                }
            } label: {
                HStack(spacing: DS.Spacing.xxs) {
                    if isPlanning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "calendar.badge.plus")
                            .font(.footnote)
                    }
                    Text("Plan \(pendingUnscheduledCount)")
                        .font(.footnote.weight(.regular).monospacedDigit())
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .fixedSize(horizontal: true, vertical: false)
                // Apple-toolbar pill: single tinted capsule fill, no
                // stroke overlay. The previous fill+strokeBorder pair
                // put two surfaces on the same pill — one surface here.
                .background(
                    Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isPlanning)
            .help("Schedule \(pendingUnscheduledCount) unscheduled task\(pendingUnscheduledCount == 1 ? "" : "s") into free slots")
            .accessibilityLabel("Plan \(pendingUnscheduledCount) unscheduled task\(pendingUnscheduledCount == 1 ? "" : "s")")
        }
    }

    // MARK: Fullscreen launcher

    /// `arrow.up.left.and.arrow.down.right` — native macOS idiom for
    /// «open fullscreen» (the same arrow on the green window traffic light).
    private func fullscreenButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.regular))
                .foregroundStyle(skin.resolvedTextSecondary)
                .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open tasks fullscreen")
        .accessibilityLabel("Open tasks fullscreen")
    }

    // MARK: Urgent pill

}

// MARK: - Convenience init for header without ETA chip (inline mode)

extension BacklogHeader where EtaContent == EmptyView {
    init(
        mode: BacklogHeaderMode,
        totalCount: Int,
        urgentCount: Int,
        pendingMinutes: Int,
        remainingWorkdayMinutes: Int,
        optimizerService: OptimizerService,
        capacityRingTooltip: String,
        useSmartSort: Binding<Bool>,
        onPlanBacklog: (() async -> Void)? = nil,
        pendingUnscheduledCount: Int = 0
    ) {
        self.init(
            mode: mode,
            totalCount: totalCount,
            urgentCount: urgentCount,
            pendingMinutes: pendingMinutes,
            remainingWorkdayMinutes: remainingWorkdayMinutes,
            optimizerService: optimizerService,
            capacityRingTooltip: capacityRingTooltip,
            useSmartSort: useSmartSort,
            onPlanBacklog: onPlanBacklog,
            pendingUnscheduledCount: pendingUnscheduledCount,
            etaChip: { EmptyView() }
        )
    }
}
