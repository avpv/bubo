import SwiftUI

/// Section header used inside the MenuBarView List
struct DaySectionHeader<Trailing: View>: View {
    let date: Date
    let count: Int
    /// Quiet meta string rendered between the title and the count badge —
    /// e.g. «next in 5 h 18 min» for today, or «all done» when no
    /// upcoming event remains. Nil for past days and future days that
    /// don't carry day-scoped state worth surfacing on the header.
    /// Mirrors the popover header's `subtitle` rhythm one level down so
    /// the typography pattern repeats from the popover top into the
    /// timeline.
    let meta: String?
    /// Optional working-hours range (e.g. `9...18`), rendered as a quiet
    /// «9–18» badge next to the count for today only. Reifies the
    /// `workingHours(start:end:)` intent at the surface where the user
    /// notices it most — the day header — so the «what counts as my
    /// work day» rule is visible, not buried in settings. Pass nil to
    /// suppress (other days, or when the host doesn't have the
    /// optimizer wired). Birman: «rules are objects on the screen».
    let workingHours: ClosedRange<Int>?
    /// Optional trailing accessory rendered after the count badge —
    /// used by the «Today» row to host the day-scope `Plan day ▾` menu
    /// next to its data. Other days pass `EmptyView` (default).
    let trailing: Trailing

    init(
        date: Date,
        count: Int,
        meta: String? = nil,
        workingHours: ClosedRange<Int>? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.date = date
        self.count = count
        self.meta = meta
        self.workingHours = workingHours
        self.trailing = trailing()
    }

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Level 4 (final): inside the timeline platter card, day headers
            // become quiet section dividers — same typographic language as
            // AddEventView's form section labels (see `SectionLabel`). Both
            // share the single `sectionHeaderStyle()` voice so one scale
            // drives every subhead in the app. For today/tomorrow we
            // colour the relative word in accent and follow with the
            // abbreviated date so the row reads «TODAY · TUE, 6 MAY»;
            // other days fall back to the long locale-aware date. The
            // accent word replaces the previous standalone today-dot —
            // one signal is enough.
            HStack(spacing: 0) {
                if let relative = relativeDayLabel {
                    Text(relative)
                        .sectionHeaderStyle()
                        .foregroundStyle(skinAccent)
                    Text(" \u{00B7} \(DS.daySectionShortFormatter.string(from: date))")
                        .sectionHeaderStyle()
                        .foregroundStyle(skin.resolvedTextTertiary)
                } else {
                    Text(dayTitle)
                        .sectionHeaderStyle()
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: DS.Spacing.xs)

            // Quiet meta — «next in 5 h 18 min», «all done», etc.
            // Rendered before the badge cluster so the badge stays the
            // rightmost anchor and the meta reads as a hint flowing
            // toward it rather than competing for the trailing edge.
            if let meta {
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                    .accessibilityLabel(meta)
            }

            // Working-hours badge — surfaces the optimizer's
            // `workingHours(start:end:)` rule at the surface that the
            // user reads first. Today only: other days share the same
            // window and the repetition would just be visual noise.
            // Hidden when `workingHours` is nil (preview surfaces, or
            // simply when the host hasn't wired the optimizer in).
            if isToday, let hours = workingHours {
                Text(formattedHours(hours))
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(
                        Capsule().fill(skin.resolvedTextTertiary.opacity(0.08))
                    )
                    .help("Working hours: \(hours.lowerBound):00–\(hours.upperBound):00")
                    .accessibilityLabel("Working hours \(hours.lowerBound) to \(hours.upperBound)")
            }

            Text("\(count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .adaptiveBadgeFill(skin.resolvedTextSecondary)
                .clipShape(Capsule())
                .contentTransition(.numericText())

            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityHeading)
        .accessibilityAddTraits(.isHeader)
    }

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    /// «Today» / «Tomorrow» when the date qualifies, nil otherwise.
    /// Drives the accent-coloured first segment in the header — e.g.
    /// «**Today** · Tue, 6 May».
    private var relativeDayLabel: String? {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return nil
    }

    /// Compact «9–18» form of the working-hours range. We strip the
    /// `:00` minutes for the common case and only spell them out
    /// when start/end land on a non-hour mark (which the current
    /// settings don't allow, but the badge stays correct if they
    /// later do).
    private func formattedHours(_ hours: ClosedRange<Int>) -> String {
        let start = hours.lowerBound
        let end = hours.upperBound
        return "\(start)\u{2013}\(end)"
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            return DS.daySectionFormatter.string(from: date)
        }
    }

    private var accessibilityHeading: String {
        let countLabel = "\(count) \(count == 1 ? "event" : "events")"
        if let meta {
            return "\(dayTitle), \(countLabel), \(meta)"
        }
        return "\(dayTitle), \(countLabel)"
    }
}
