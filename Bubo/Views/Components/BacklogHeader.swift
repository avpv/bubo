import SwiftUI

// MARK: - Mode

/// Чтение режима, в котором рендерится `BacklogHeader`. Inline-карточка
/// и fullscreen-popover делят один компонент, но различаются в двух
/// деталях: можно ли свернуть список (chevron + count → button vs plain
/// text) и есть ли кнопка «развернуть на весь экран». Всё остальное —
/// ring, capacity verdict, smart-sort toggle, urgent pill — одинаково
/// в обоих режимах.
enum BacklogHeaderMode {
    /// Inline в карточке Tasks на главном popover'е. Header умеет
    /// сворачиваться/разворачиваться (chevron + кнопка переключения),
    /// и предлагает кнопку «развернуть на весь экран».
    case inline(
        expansion: Binding<TaskListExpansion>,
        onEnterFullscreen: (() -> Void)?
    )
    /// Fullscreen-карточка backlog'а во весь popover. Без chevron'а —
    /// сворачивать некуда: это и есть полная карточка.
    case fullscreen
}

// MARK: - Header

/// Mode-aware header for both backlog presentations: inline (collapsible
/// card on the main popover) and fullscreen (whole-popover card).
///
/// Раньше каждый режим держал свой header'овский HStack как private
/// `@ViewBuilder`, и любая правка («tasks» suffix у count'а, urgent pill
/// на свою строку, smart-sort всегда видим) приходилось зеркалить в двух
/// файлах — и пару раз они едва не разъехались по тултипам и accessibility-
/// меткам. Теперь оба режима собирают header'а через этот компонент:
/// вариативные части — `Mode` enum, общий каркас (ring → count → sort →
/// fullscreen-btn, и под ним verdict + urgent) описан здесь и менять его
/// нужно ровно в одном месте.
///
/// Внутри:
///   - Header HStack: ring, count, eta, sort, spacer, [fullscreen-btn для inline]
///   - Capacity verdict отдельной строкой под header'ом (в обоих режимах)
///   - Urgent pill отдельной строкой (когда `urgentCount > 0`, в обоих режимах)
///
/// Inline-режим прокидывает `expansion` и `onEnterFullscreen` через
/// `Mode.inline`. Smart-sort и urgent toggles в этом режиме умеют
/// «приоткрыть» свёрнутый список (`.collapsed → .compact`), иначе
/// фильтрация пряталась бы за свёрнутым header'ом.
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
            // Capacity verdict отдельной строкой под header'ом в обоих
            // режимах: иначе красный warning зажимал бы header в спорный за
            // внимание ряд. Раньше fullscreen клал verdict внутрь headerRow
            // рядом с count'ом, и inline/fullscreen верстались по-разному —
            // теперь оба читаются одинаково.
            if totalCount > 0 {
                BacklogCapacityLabel(
                    pendingMinutes: pendingMinutes,
                    overflowingCount: 0,
                    optimizerService: optimizerService
                )
            }
            // Urgent pill — на своей строке в обоих режимах. Раньше зажимал
            // header вместе с over-capacity warning'ом за один красный канал.
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

            // Project picker — Reminders.app-style switcher между листами.
            // Видим только когда sync с Apple Reminders включён и есть
            // EventKit-доступ; в противном случае проектов в Bubo физически
            // не существует (см. `BacklogProjectPicker`). Стоит у правого
            // края рядом с fullscreen-кнопкой, чтобы читался как «context
            // навигация», а не как часть числового header'а слева.
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

    // MARK: Count

    /// Inline режим оборачивает count в кнопку с chevron'ом
    /// (collapsed/compact toggle); fullscreen — это просто число (карточка
    /// и так раскрыта на весь popover, чевронить нечего).
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
                // Engaging smart-sort while collapsed would hide the
                // reordered list — open to `.compact` so the new order is
                // visible. Fullscreen режим не имеет collapsed-состояния и
                // на этот side-effect не реагирует.
                if useSmartSort,
                   case .inline(let expansion, _) = mode,
                   expansion.wrappedValue == .collapsed {
                    expansion.wrappedValue = .compact
                }
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

    /// `arrow.up.left.and.arrow.down.right` — родная macOS-идиома
    /// «развернуть на весь экран» (та же стрелка на зелёном светофоре окна).
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
                // Engaging the filter while the list is collapsed would
                // hide everything — open to `.compact` so the filtered set
                // is immediately visible. Fullscreen-режим не имеет
                // collapsed-состояния и на этот side-effect не реагирует.
                if urgentOnlyFilter,
                   case .inline(let expansion, _) = mode,
                   expansion.wrappedValue == .collapsed {
                    expansion.wrappedValue = .compact
                }
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

// MARK: - Convenience init for header без ETA-чипа (inline-режим)

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
