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
        // Matches the prototype's `.day-header`: a full-bleed sticky
        // strip with uppercase tracked 11pt body, accent-coloured
        // relative day, dim summary on the trailing edge. The
        // background is a subtle darker translucent overlay so the
        // strip reads as a banner between event clusters.
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            HStack(spacing: 0) {
                if let relative = relativeDayLabel {
                    Text(relative.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: skin.resolvedFontDesign))
                        .tracking(0.4)
                        .foregroundStyle(skinAccent)
                    Text(" \u{00B7} \(DS.daySectionShortFormatter.string(from: date))")
                        .font(.system(size: 11, weight: .semibold, design: skin.resolvedFontDesign))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(skin.resolvedTextSecondary)
                } else {
                    Text(dayTitle)
                        .font(.system(size: 11, weight: .semibold, design: skin.resolvedFontDesign))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: DS.Spacing.xs)

            // Summary: «3 events» or «5 events · next in 5 h 18 min».
            // Lighter than the date label so the trailing edge reads
            // as a hint rather than a competing title.
            Text(summaryString)
                .font(.system(size: 11, weight: .regular, design: skin.resolvedFontDesign))
                .tracking(0.2)
                .foregroundStyle(skin.resolvedTextTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            trailing
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // `.day-header` translucent surface-window backdrop.
            // Use a hairline darker overlay so the strip reads as a
            // banner regardless of the skin's base colour.
            Rectangle()
                .fill(skin.resolvedTextPrimary.opacity(0.04))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(skin.resolvedTextPrimary.opacity(0.06))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityHeading)
        .accessibilityAddTraits(.isHeader)
    }

    /// Compact «5 events · next in 5 h 18 min» line on the trailing
    /// edge of the banner. Drops the meta clause when nil (other days)
    /// and pluralises the count.
    private var summaryString: String {
        let countCopy = "\(count) \(count == 1 ? "event" : "events")"
        if let meta {
            return "\(countCopy) \u{00B7} \(meta)"
        }
        return countCopy
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
