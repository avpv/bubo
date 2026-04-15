import SwiftUI

/// Section header used inside the MenuBarView List
struct DaySectionHeader: View {
    let date: Date
    let count: Int

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
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .adaptiveBadgeFill(skin.resolvedTextSecondary)
                .clipShape(Capsule())
                .contentTransition(.numericText())
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
