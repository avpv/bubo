import SwiftUI

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
    @Binding var urgentOnlyFilter: Bool

    @ViewBuilder let etaChip: () -> EtaContent

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ReminderSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            headerRow
            // Capacity verdict on a separate line below the header in both
            // modes: otherwise the red warning would squeeze the header
            // into a row that fights for attention. Previously fullscreen
            // put the verdict inside headerRow next to the count, and
            // inline/fullscreen laid out differently — now both read the same.
            if totalCount > 0 {
                BacklogCapacityLabel(
                    pendingMinutes: pendingMinutes,
                    overflowingCount: 0,
                    optimizerService: optimizerService
                )
            }
            // Urgent pill — on its own line in both modes. Previously it
            // squeezed the header together with the over-capacity warning
            // into a single red channel.
            if urgentCount > 0 {
                urgentFilterButton
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: Header row

    private var headerRow: some View {
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

            if totalCount > 1 {
                smartSortButton
            }

            Spacer(minLength: 0)

            // Project picker — Reminders.app-style switcher between projects.
            // Always visible: shows the union of local Bubo projects
            // (`settings.localProjects`) and Apple Reminders lists (when
            // EventKit access is granted and sync is enabled). Sits at the
            // right edge next to the fullscreen button, so it reads as
            // «context navigation», not as part of the numeric header on the left.
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
        let label = "\(totalCount) task\(totalCount == 1 ? "" : "s")"
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
        Button {
            // `.levelChange` for sort-order switch — list reorders, discrete
            // state change. Same haptic on both directions of the toggle.
            Haptics.impact()
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                useSmartSort.toggle()
                expandIfCollapsed(whenEnabled: useSmartSort)
            }
        } label: {
            Image(systemName: useSmartSort ? "wand.and.stars" : "arrow.up.arrow.down")
                .font(.footnote.weight(.medium))
                .foregroundStyle(useSmartSort ? skin.accentColor : skin.resolvedTextSecondary)
                .frame(width: DS.Size.iconLarge, height: DS.Size.iconLarge)
                .background(
                    Circle().fill(
                        skin.accentColor.opacity(useSmartSort ? DS.Opacity.lightFill : 0)
                    )
                )
                .contentShape(Circle())
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

    // MARK: Fullscreen launcher

    /// `arrow.up.left.and.arrow.down.right` — native macOS idiom for
    /// «open fullscreen» (the same arrow on the green window traffic light).
    private func fullscreenButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)
                .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open tasks fullscreen")
        .accessibilityLabel("Open tasks fullscreen")
    }

    // MARK: Urgent pill

    /// `urgentColor` (desaturated red) sits in the same family as the
    /// over-capacity ring's saturated red but at lower intensity, so the
    /// two no longer fight for the same eye fix. The ring keeps the
    /// «something is broken» voice; this pill says «N items are
    /// time-sensitive» — informational urgency.
    private var urgentFilterButton: some View {
        Button {
            // `.levelChange` haptic for filter mode switch — discrete
            // state change «list narrows / list opens up».
            Haptics.impact()
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                urgentOnlyFilter.toggle()
                expandIfCollapsed(whenEnabled: urgentOnlyFilter)
            }
        } label: {
            Text("\(urgentCount) urgent")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.resolvedUrgentColor)
                .contentTransition(.numericText())
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(
                    Capsule().fill(
                        skin.resolvedUrgentColor.opacity(urgentOnlyFilter ? DS.Opacity.lightFill : 0)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        skin.resolvedUrgentColor.opacity(urgentOnlyFilter ? DS.Opacity.softAccent : 0),
                        lineWidth: DS.Border.thin
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(urgentOnlyFilter ? "Show all tasks" : "Show only urgent tasks")
        .accessibilityLabel(
            urgentOnlyFilter
                ? "Showing only urgent tasks — tap to clear filter"
                : "\(urgentCount) urgent tasks — tap to filter"
        )
    }
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
        urgentOnlyFilter: Binding<Bool>
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
            urgentOnlyFilter: urgentOnlyFilter,
            etaChip: { EmptyView() }
        )
    }
}
