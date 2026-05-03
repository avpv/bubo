import SwiftUI

// MARK: - Week Strip View

/// Horizontal seven-dot strip showing each weekday's relative load —
/// the visual reification of the optimizer's `planWeek` / `horizon`
/// intents. Sits in the fullscreen Backlog header so the user can see
/// where the queue is heavy and where it has slack at a glance,
/// without opening a separate week view.
///
/// Each dot is a mini capacity ring (filled fraction = load /
/// dailyBudget). The active day is rendered larger and tinted with
/// `skin.accentColor`; inactive days share a muted secondary tint.
/// Tap on a dot calls `onSelectDay(_:)` so the host can rebase its
/// filter to that day. Birman: «rules are objects on the screen» —
/// the week itself becomes a draggable surface, not a hidden setting.
///
/// This first revision uses deadline-based loads as the proxy for
/// «how much work this day carries». A follow-up commit promotes it
/// to honour the optimizer's actual per-day assignments once the
/// shadow proposal lands.
struct WeekStripView: View {

    /// Per-day load datum.
    struct DayLoad: Identifiable, Equatable {
        let id: Date  // start-of-day
        let date: Date
        let workloadMinutes: Int
        let budgetMinutes: Int

        /// 0…1 fraction, clamped. > 1 is rendered as «over» visually
        /// (ring fills past 1 in the destructive colour).
        var fraction: Double {
            guard budgetMinutes > 0 else { return workloadMinutes > 0 ? 1.0 : 0 }
            return min(1.5, Double(workloadMinutes) / Double(budgetMinutes))
        }

        var isOverbudget: Bool { fraction > 1.0 }
    }

    let days: [DayLoad]
    let selectedDay: Date
    let onSelectDay: (Date) -> Void

    @Environment(\.activeSkin) private var skin

    var body: some View {
        // Three-letter labels (Mon/Tue/…) plus the dots can outgrow
        // narrow hosts. Mirror `WorkingDaysPicker` and fall back to
        // a horizontal scroll so the strip never compresses or wraps;
        // on wider hosts the row already fits and the scroll is
        // invisible.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(days) { day in
                    dayDot(day)
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
        }
    }

    // MARK: - Dot

    @ViewBuilder
    private func dayDot(_ day: DayLoad) -> some View {
        let isActive = Calendar.current.isDate(day.date, inSameDayAs: selectedDay)
        let label = Self.label(for: day.date)
        let isToday = Calendar.current.isDateInToday(day.date)
        Button {
            Haptics.tap()
            onSelectDay(day.date)
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.caption2.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? skin.accentColor : skin.resolvedTextTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                ZStack {
                    Circle()
                        .stroke(skin.resolvedTextTertiary.opacity(0.3), lineWidth: 1)
                        .frame(width: isActive ? 14 : 10, height: isActive ? 14 : 10)
                    Circle()
                        .trim(from: 0, to: min(1.0, day.fraction))
                        .stroke(
                            day.isOverbudget ? skin.resolvedDestructiveColor
                                             : skin.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: isActive ? 14 : 10, height: isActive ? 14 : 10)
                        .rotationEffect(.degrees(-90))
                }
                // Tiny dot below the day's load ring marks «today»
                // even when today isn't the active filter, so the
                // user always has a calibration point. Hidden when
                // today IS the selected day (`isActive`) — the
                // larger ring already conveys it.
                if isToday && !isActive {
                    Circle()
                        .fill(skin.accentColor)
                        .frame(width: 3, height: 3)
                } else {
                    // Reserved space so the strip's vertical rhythm
                    // stays aligned across days regardless of which
                    // one is today.
                    Color.clear.frame(width: 3, height: 3)
                }
            }
            .padding(.horizontal, DS.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip(for: day, isActive: isActive))
        .accessibilityLabel(accessibilityLabel(for: day, isActive: isActive))
    }

    // MARK: - Strings

    /// Three-letter English weekday labels, indexed by Foundation's
    /// 1…7 weekday convention (1 = Sun). Matches `WorkingDaysPicker`
    /// so the same chips read identically across the popover and the
    /// week strip.
    private static let weekdayLabels: [String] = [
        "", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"
    ]

    private static func label(for date: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekdayLabels[weekday]
    }

    private func tooltip(for day: DayLoad, isActive: Bool) -> String {
        let workload = DS.formatMinutes(day.workloadMinutes)
        let budget = DS.formatMinutes(day.budgetMinutes)
        let fullDay = day.date.formatted(date: .abbreviated, time: .omitted)
        let prefix = isActive ? "\(fullDay) (selected)" : fullDay
        if day.isOverbudget {
            return "\(prefix): \(workload) of \(budget) — over capacity"
        }
        return "\(prefix): \(workload) of \(budget)"
    }

    private func accessibilityLabel(for day: DayLoad, isActive: Bool) -> String {
        let dayName = day.date.formatted(.dateTime.weekday(.wide))
        let pct = Int((min(1.5, day.fraction) * 100).rounded())
        return "\(dayName), \(pct) percent loaded\(isActive ? ", selected" : "")"
    }
}

// MARK: - Builder helpers

extension WeekStripView.DayLoad {
    /// Build a 7-day load array starting at the calendar week containing
    /// `now`. Each day's `workloadMinutes` sums:
    ///   - durations of `tasks` whose `deadline` falls on that day
    ///     (deadline pressure the user has set on the backlog);
    ///   - durations of `events` whose `startTime` falls on that day
    ///     (already-scheduled commitments).
    /// `budgetMinutes` is the `workingHours` window in minutes (or zero
    /// for non-working days when `workingDays` is set, so the dot
    /// renders empty).
    ///
    /// Pure — no Date() reads beyond the `now` parameter — so it tests
    /// cleanly. Used by `BacklogFullscreenView` to seed `WeekStripView`.
    static func week(
        for tasks: [BacklogTask],
        events: [CalendarEvent] = [],
        workingHours: ClosedRange<Int>,
        workingDays: Set<Int> = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WeekStripView.DayLoad] {
        let weekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? now
        let dailyMinutes = max(0, (workingHours.upperBound - workingHours.lowerBound) * 60)

        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                return nil
            }
            let isWorkingDay: Bool = {
                if workingDays.isEmpty { return true }
                let weekday = calendar.component(.weekday, from: day)
                return workingDays.contains(weekday)
            }()
            let dayMinutes = isWorkingDay ? dailyMinutes : 0

            let taskMinutes = tasks
                .filter { task in
                    guard let deadline = task.deadline else { return false }
                    return calendar.isDate(deadline, inSameDayAs: day)
                }
                .reduce(0) { $0 + $1.durationMinutes }

            let eventMinutes = events
                .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
                .reduce(0) { acc, ev in
                    acc + max(0, Int(ev.endDate.timeIntervalSince(ev.startDate) / 60))
                }

            return WeekStripView.DayLoad(
                id: calendar.startOfDay(for: day),
                date: day,
                workloadMinutes: taskMinutes + eventMinutes,
                budgetMinutes: dayMinutes
            )
        }
    }
}
