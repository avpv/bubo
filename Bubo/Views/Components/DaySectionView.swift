import SwiftUI

/// Section header used inside the MenuBarView List
struct DaySectionHeader<Trailing: View>: View {
    let date: Date
    let count: Int
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
        workingHours: ClosedRange<Int>? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.date = date
        self.count = count
        self.workingHours = workingHours
        self.trailing = trailing()
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin
    @State private var appeared = false

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Level 4 (final): inside the timeline platter card, day headers
            // become quiet section dividers — same typographic language as
            // AddEventView's form section labels (see `SectionLabel`). Both
            // share the single `sectionHeaderStyle()` voice so one scale
            // drives every subhead in the app. The today dot and the count
            // badge carry the visual weight on the right side of the row,
            // keeping the header informative without shouting.
            Text(dayTitle)
                .sectionHeaderStyle()
                .foregroundStyle(skin.resolvedTextTertiary)
                .fixedSize(horizontal: true, vertical: false)
            if isToday {
                Circle()
                    .fill(skinAccent)
                    .frame(width: DS.Size.todayDotSize, height: DS.Size.todayDotSize)
                    .scaleEffect(appeared ? 1 : 0)
            }
            Spacer(minLength: DS.Spacing.xs)

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
        .accessibilityLabel("\(dayTitle), \(count) \(count == 1 ? "event" : "events")")
        .accessibilityAddTraits(.isHeader)
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(DS.Animation.gentleBounce.delay(0.15)) {
                appeared = true
            }
        }
    }

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
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
}
