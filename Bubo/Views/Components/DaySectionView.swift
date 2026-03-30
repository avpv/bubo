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
            Text(dayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(isToday ? skinAccent : skin.resolvedTextPrimary)
            if isToday {
                Circle()
                    .fill(skinAccent)
                    .frame(width: DS.Size.todayDotSize, height: DS.Size.todayDotSize)
                    .scaleEffect(appeared ? 1 : 0)
            }
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
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
