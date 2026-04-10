import SwiftUI

// MARK: - Free Slot Row
//
// A first-class row inserted between events to represent empty time.
// Clicking the + icon opens the CommandPalette pre-seeded with the slot duration,
// which filters the recipe list to creative recipes that fit the slot.
//
// This is the "direct manipulation on empty time" layer of the optimizer UI —
// users see that a gap exists and can fill it without typing.

struct FreeSlotRow: View {
    @Environment(\.activeSkin) private var skin

    let start: Date
    let end: Date
    let onFillTapped: (_ minutes: Int) -> Void
    /// Called when a backlog task is dropped onto this slot.
    var onTaskDropped: ((_ taskId: String) -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isDropTargeted: Bool = false

    private var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    private var formattedRange: String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return "\(fmt.string(from: start))–\(fmt.string(from: end))"
    }

    private var durationLabel: String {
        if durationMinutes < 60 {
            return "\(durationMinutes)\u{00A0}min"
        }
        let h = durationMinutes / 60
        let m = durationMinutes % 60
        return m == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h \(m)\u{00A0}min"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Dashed guide to visually distinguish from event rows
            Rectangle()
                .fill(skin.resolvedTextTertiary.opacity(0.35))
                .frame(width: DS.Size.accentBarWidth, height: 2)
                .padding(.trailing, DS.Spacing.md)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("Free · \(durationLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                Text(formattedRange)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }

            Spacer(minLength: DS.Spacing.md)

            Button {
                Haptics.tap()
                onFillTapped(durationMinutes)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundStyle(skin.accentColor.opacity(isHovered ? 1.0 : 0.55))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fill this slot")
            .accessibilityLabel("Fill this \(durationLabel) free slot")
        }
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(isHovered ? skin.accentColor.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    skin.resolvedTextTertiary.opacity(isHovered ? 0.25 : 0.12),
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                )
        )
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let taskId = items.first, onTaskDropped != nil else { return false }
            onTaskDropped?(taskId)
            return true
        } isTargeted: { targeted in
            withAnimation(skin.resolvedMicroAnimation) {
                isDropTargeted = targeted
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? skin.accentColor : Color.clear,
                    lineWidth: isDropTargeted ? 2 : 0
                )
                .animation(skin.resolvedMicroAnimation, value: isDropTargeted)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Free Slot Computation
//
// Pure helper used by the event list to compute the free gaps between events.
// Kept here so it can be unit-tested separately from MenuBarView.

enum FreeSlotFinder {
    /// Default minimum slot length (in minutes) below which we hide the row
    /// to avoid cluttering the list with tiny gaps. Callers can override.
    static let defaultMinSlotMinutes: Int = 30

    /// Returns the free gaps for today between `events` within working hours.
    /// The caller passes already-sorted events for the day.
    /// `minSlotMinutes` controls the shortest gap shown (defaults to 30).
    static func slots(
        for events: [CalendarEvent],
        on date: Date,
        workingHours: ClosedRange<Int>,
        minSlotMinutes: Int = defaultMinSlotMinutes
    ) -> [(start: Date, end: Date)] {
        let cal = Calendar.current
        guard let dayStart = cal.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: date),
              let dayEnd = cal.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: date)
        else {
            return []
        }

        let now = Date()
        let effectiveStart = max(dayStart, cal.isDateInToday(date) ? now : dayStart)
        guard effectiveStart < dayEnd else { return [] }

        // Only count non-all-day, in-window events as occupying time.
        let relevant = events
            .filter { $0.endDate > effectiveStart && $0.startDate < dayEnd }
            .sorted { $0.startDate < $1.startDate }

        var gaps: [(start: Date, end: Date)] = []
        var cursor = effectiveStart

        for event in relevant {
            let eStart = max(event.startDate, effectiveStart)
            if eStart > cursor {
                let minutes = Int(eStart.timeIntervalSince(cursor) / 60)
                if minutes >= minSlotMinutes {
                    gaps.append((cursor, eStart))
                }
            }
            cursor = max(cursor, min(event.endDate, dayEnd))
        }

        if cursor < dayEnd {
            let minutes = Int(dayEnd.timeIntervalSince(cursor) / 60)
            if minutes >= minSlotMinutes {
                gaps.append((cursor, dayEnd))
            }
        }

        return gaps
    }
}
