import Foundation

// MARK: - Schedule horizon helpers
//
// File-scope helpers shared by `ScheduleChromosome`'s initialisation,
// mutation, and repair paths. Extracted from `Chromosome.swift` so the
// chromosome file isn't burdened by date-arithmetic utilities that have
// no dependency on the struct itself.

/// Move `date` forward to the first working day still inside the horizon
/// (as defined by `workingDays` — set of 1-indexed weekdays where
/// 1 = Sunday, 7 = Saturday), snapping the time-of-day to the
/// working-hours lower bound when the day is rolled over. Returns
/// `date` unchanged when it's already on a working day, when
/// `workingDays` is empty (no filter), or when the horizon contains
/// no working day at all (in which case the caller's constraint
/// penalty is the right signal — repairing can't manufacture
/// feasibility that doesn't exist).
func advancePastNonWorkingDay(
    from date: Date,
    workingHours: ClosedRange<Int>,
    horizon: DateInterval,
    calendar: Calendar,
    workingDays: Set<Int>
) -> Date {
    if workingDays.isEmpty { return date }
    if workingDays.contains(calendar.component(.weekday, from: date)) { return date }
    // Walk day by day until we find a working day inside the horizon.
    // Guard the loop at 14 iterations — enough for any realistic
    // planning horizon and keeps a pathological calendar from
    // looping forever.
    public var cursor = calendar.startOfDay(for: date)
    for _ in 0..<14 {
        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
        if cursor >= horizon.end { return date }
        if workingDays.contains(calendar.component(.weekday, from: cursor)) {
            if let dayStart = calendar.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: cursor) {
                return dayStart
            }
            return cursor
        }
    }
    return date
}

func clampToWorkingHours(
    _ date: Date,
    duration: TimeInterval,
    workingHours: ClosedRange<Int>,
    calendar: Calendar,
    floor: Date? = nil
) -> Date {
    public let day = calendar.startOfDay(for: date)
    guard let workStart = calendar.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day),
          let workEnd = calendar.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day) else {
        return date
    }

    // Clamp start so event doesn't begin before working hours or floor
    public let lowerBound = if let floor { max(workStart, floor) } else { workStart }
    public var clamped = max(date, lowerBound)

    // Clamp start so event doesn't end after working hours
    public let latestStart = workEnd.addingTimeInterval(-duration)
    if latestStart >= lowerBound {
        clamped = min(clamped, latestStart)
    } else {
        // Duration exceeds available window — start at lower bound
        clamped = lowerBound
    }

    return clamped
}
