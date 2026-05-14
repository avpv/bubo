import Foundation
import BuboDomain

// MARK: - ScheduleChromosome slot-search helpers
//
// Forward / reverse gap walks and multi-signal feasible-slot enumeration
// shared between seeding (`Chromosome+CPSATSeed.swift`), initialisation
// (`Chromosome+Initialization.swift`), and the LNS repair pipeline
// (`Chromosome+CPSATRepair.swift`). Extracted from `Chromosome+CPSATSeed.swift`
// on 2026-05-13 so each file stays under ~500 lines:
//
//   • `findFirstFreeSlot(...)` — forward gap walk.
//   • `findLastFreeSlot(...)`  — backward gap walk, mirror semantics.
//   • `enumerateFeasibleSlots(...)` — multi-signal-scored domain
//     enumeration consumed by the BnB inner loop.
//   • `OccupiedInterval` — bookkeeping struct carrying enough metadata
//     (context, focus-block flag) for the cpRepair signal proxies.
//
// All members are `public` so callers in sibling files reach them
// across the file boundary without further visibility relaxations.

public extension ScheduleChromosome {

    // MARK: - Slot search

    /// Find the first gap in the schedule that fits the event duration.
    ///
    /// Called from seeding, `Chromosome+Initialization.swift`
    /// (`random(...)` / `greedyWithOrder(...)`), and the LNS repair
    /// bridge in `Chromosome+CPSATRepair.swift`.
    static func findFirstFreeSlot(
        duration: TimeInterval,
        preferredHours: ClosedRange<Int>?,
        occupied: [(start: Date, end: Date)],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        earliestStart: Date?,
        deadline: Date?,
        dependsOn: [String],
        placedGenes: [ScheduleGene],
        genesByEvent: [String: Int],
        workingDays: Set<Int> = [],
        eventId: String? = nil,
        context: OptimizerContext? = nil
    ) -> Date? {
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        // Earliest possible start considering dependencies
        var floor = earliestStart ?? horizon.start
        if floor < horizon.start { floor = horizon.start }
        for depId in dependsOn {
            if let depGene = placedGenes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                floor = max(floor, depGene.endTime)
            }
        }

        // Fast path: consult the precomputed per-event slot domain
        // when the caller supplied both `eventId` and `context`.
        // The domain already encodes `earliestStart`, event-level
        // `deadline`, working-hours fit and fixed-event non-overlap,
        // so the only runtime filters are:
        //   • the chromosome-specific `occupied` intervals;
        //   • the dependency-derived `floor` above;
        //   • a caller-supplied `deadline` that may be *tighter*
        //     than the event's static deadline (LNS reverse-deps).
        // Iterating the domain (typically ≤200 entries) is strictly
        // cheaper than the day-by-day stride walk below (~28×h
        // working hours × slots-per-hour).
        if let eventId, let context {
            let registry = context.ensureSlotRegistry()
            let domain = context.ensureSlotDomain(for: eventId)
            if !domain.isEmpty {
                let feasibleStart = domain.indices(after: floor, registry: registry)
                for idx in feasibleStart {
                    guard let candidate = registry.resolvedDate(at: idx) else { continue }
                    let candidateEnd = candidate.addingTimeInterval(duration)
                    // Dynamic deadline (tighter than static) — break
                    // on overshoot since domain is chronologically
                    // sorted, so every later entry overshoots too.
                    if let deadline, candidateEnd > deadline { break }
                    let hasOverlap = occupied.contains { occ in
                        candidate < occ.end && candidateEnd > occ.start
                    }
                    if !hasOverlap {
                        return candidate
                    }
                }
                // Domain was non-empty but every entry conflicts
                // with current `occupied` (or dynamic deadline) —
                // no feasible slot.
                return nil
            }
        }

        // Try each day, preferring preferred hours
        for dayOffset in 0..<daysInHorizon {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
            // Skip non-working days when the caller asked us to — matches
            // the `WorkingHoursConstraint` day-of-week branch so greedy
            // seeding and LNS re-insertion don't probe days the hard
            // constraint will immediately reject. Empty set = no filter
            // (legacy caller that doesn't care about day-of-week).
            if !workingDays.isEmpty {
                let weekday = calendar.component(.weekday, from: day)
                if !workingDays.contains(weekday) { continue }
            }
            let hourRange = preferredHours ?? workingHours
            guard let dayWorkStart = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
                  let dayWorkEnd = calendar.date(bySettingHour: min(hourRange.upperBound, workingHours.upperBound), minute: 0, second: 0, of: day) else { continue }

            // Candidate starts at 15-minute intervals
            var candidate = max(dayWorkStart, floor)
            let latestStart = dayWorkEnd.addingTimeInterval(-duration)
            if let deadline, latestStart > deadline.addingTimeInterval(-duration) {
                continue // whole day is past deadline
            }

            while candidate <= latestStart {
                let candidateEnd = candidate.addingTimeInterval(duration)

                // Check deadline
                if let deadline, candidateEnd > deadline { break }

                // Check overlap with occupied intervals
                let hasOverlap = occupied.contains { occ in
                    candidate < occ.end && candidateEnd > occ.start
                }

                if !hasOverlap {
                    return candidate
                }

                // Jump past the overlapping event (minimum 1-minute advance to prevent infinite loop)
                if let blocker = occupied.first(where: { candidate < $0.end && candidateEnd > $0.start }) {
                    let nextCandidate = blocker.end
                    candidate = nextCandidate > candidate ? nextCandidate : candidate.addingTimeInterval(900)
                } else {
                    candidate = candidate.addingTimeInterval(900) // 15 min
                }
            }
        }

        return nil
    }

    /// Symmetric counterpart to `findFirstFreeSlot`: walks the horizon in
    /// reverse and returns the *latest* feasible start time that still
    /// respects working hours, the deadline, the earliestStart/dependency
    /// floor, and every interval in `occupied`. Used by the LNS regret
    /// insertion to measure each gene's placement window — the smaller
    /// the gap between earliest and latest, the tighter the gene and the
    /// higher its regret if deferred.
    ///
    /// Returns `nil` when no 15-minute-aligned slot fits anywhere. Same
    /// semantics as `findFirstFreeSlot`: dependency satisfaction is
    /// checked against `placedGenes`, the caller supplies `occupied`
    /// minus any genes that are themselves about to move.
    static func findLastFreeSlot(
        duration: TimeInterval,
        preferredHours: ClosedRange<Int>?,
        occupied: [(start: Date, end: Date)],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        earliestStart: Date?,
        deadline: Date?,
        dependsOn: [String],
        placedGenes: [ScheduleGene],
        genesByEvent: [String: Int],
        workingDays: Set<Int> = []
    ) -> Date? {
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        var floor = earliestStart ?? horizon.start
        if floor < horizon.start { floor = horizon.start }
        for depId in dependsOn {
            if let depGene = placedGenes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                floor = max(floor, depGene.endTime)
            }
        }

        let ceiling = deadline.map { min($0, horizon.end) } ?? horizon.end

        // Walk days in reverse, searching for the latest feasible start.
        for dayOffset in stride(from: daysInHorizon - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
            if !workingDays.isEmpty {
                let weekday = calendar.component(.weekday, from: day)
                if !workingDays.contains(weekday) { continue }
            }
            let hourRange = preferredHours ?? workingHours
            guard let dayWorkStart = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
                  let dayWorkEnd = calendar.date(bySettingHour: min(hourRange.upperBound, workingHours.upperBound), minute: 0, second: 0, of: day) else { continue }

            let dayFloor = max(dayWorkStart, floor)
            let dayEnd = min(dayWorkEnd, ceiling)
            let latestStartOnDay = dayEnd.addingTimeInterval(-duration)
            if latestStartOnDay < dayFloor { continue }

            // Snap latestStartOnDay down to a 15-min grid so we match
            // findFirstFreeSlot's stepping and the two functions agree on
            // boundary cases.
            let secs = latestStartOnDay.timeIntervalSinceReferenceDate
            let snapped = Date(timeIntervalSinceReferenceDate: (secs / 900).rounded(.down) * 900)
            var candidate = min(latestStartOnDay, snapped)

            while candidate >= dayFloor {
                let candidateEnd = candidate.addingTimeInterval(duration)
                if candidateEnd <= ceiling {
                    let hasOverlap = occupied.contains { occ in
                        candidate < occ.end && candidateEnd > occ.start
                    }
                    if !hasOverlap {
                        return candidate
                    }
                }

                // Step back before the blocker so we skip its span in
                // one jump; otherwise retreat by 15 minutes.
                if let blocker = occupied.first(where: { candidate < $0.end && candidateEnd > $0.start }) {
                    let prevEnd = blocker.start.addingTimeInterval(-duration)
                    let s = prevEnd.timeIntervalSinceReferenceDate
                    candidate = Date(timeIntervalSinceReferenceDate: (s / 900).rounded(.down) * 900)
                } else {
                    candidate = candidate.addingTimeInterval(-900)
                }
            }
        }

        return nil
    }

    /// Occupied time interval carrying the gene/event metadata that the
    /// LNS cost proxy needs to score richer objectives (ContextSwitch,
    /// BreakPlacement, WeekBalance). Only `enumerateFeasibleSlots` and
    /// `cpRepair` use this shape — other repair paths keep the simpler
    /// `(start: Date, end: Date)` tuple to avoid a cross-cutting refactor.
    struct OccupiedInterval {

        public init(
            start: Date,
            end: Date,
            context: String?,
            isFocusBlock: Bool
        ) {
            self.start = start
            self.end = end
            self.context = context
            self.isFocusBlock = isFocusBlock
        }

        public let start: Date
        public let end: Date
        /// The event's context tag (e.g. project name). `nil` when the
        /// source is a fixed calendar event with no tag.
        public let context: String?
        /// `true` when the occupying item is a focus block — used by the
        /// focus-block continuity signal to skip focus-within-focus
        /// rewards.
        public let isFocusBlock: Bool
    }

    /// Enumerate the top-K feasible start slots for one gene against a
    /// given occupied set, sorted by a cost proxy that approximates the
    /// GA's real fitness. Used by the CP branch-and-bound repair as the
    /// per-gene domain.
    ///
    /// Cost proxy weights eleven per-slot signals, each mapping to one or
    /// more of the 13 GA objectives. The full signal list, with the GA
    /// objective it proxies:
    ///
    ///   1. Preferred-hour fit        → TaskPlacement, PomodoroFit
    ///   2. Energy alignment          → EnergyBalance
    ///   3. Buffer gap                → Buffer
    ///   4. Deadline slack            → Deadline
    ///   5. Focus-block continuity    → FocusBlock
    ///   6. Meeting clustering        → MeetingClustering
    ///   7. Earliness                 → tie-breaker
    ///   8. Context switch            → ContextSwitch       (requires rich occupied)
    ///   9. Pomodoro alignment        → PomodoroFit
    ///  10. Break placement           → BreakPlacement      (requires rich occupied)
    ///  11. Week balance              → WeekBalance         (requires rich occupied)
    ///
    /// Signals 8, 10, 11 lean on `OccupiedInterval.context` and same-day
    /// density; the others work from time-only information. All weights
    /// scale with matching user `OptimizerPreferences` so the proxy
    /// adapts to individual emphasis. The cost is a search heuristic,
    /// not a fitness substitute — the real evaluator recomputes after
    /// mutation. The proxy's job is to keep BnB pruning on the right
    /// side of the fitness landscape while committing to placements.
    static func enumerateFeasibleSlots(
        duration: TimeInterval,
        topK: Int,
        preferredHours: ClosedRange<Int>?,
        occupied: [OccupiedInterval],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        earliestStart: Date?,
        deadline: Date?,
        dependsOn: [String],
        placedGenes: [ScheduleGene],
        energyCost: Double,
        isFocusBlock: Bool,
        geneContext: String?,
        preferences: OptimizerPreferences
    ) -> [(slot: Date, cost: Double)] {
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        var floor = earliestStart ?? horizon.start
        if floor < horizon.start { floor = horizon.start }
        for depId in dependsOn {
            if let depGene = placedGenes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                floor = max(floor, depGene.endTime)
            }
        }
        let ceiling = deadline.map { min($0, horizon.end) } ?? horizon.end
        let horizonSecs = max(1, horizon.end.timeIntervalSince(horizon.start))

        let requiredBufferSecs = TimeInterval(
            (energyCost > 0.7
                ? preferences.heavyMeetingBufferMinutes
                : preferences.defaultBufferMinutes
            ) * 60
        )
        let idealFocusSecs = TimeInterval(preferences.idealFocusBlockMinutes * 60)
        let minBreakSecs = TimeInterval(preferences.minBreakMinutes * 60)
        let clusterWindow = preferences.preferredClusterWindowStart..<preferences.preferredClusterWindowEnd
        let maxPerDay = max(1, preferences.maxMeetingsPerDay)

        var candidates: [(slot: Date, cost: Double)] = []
        candidates.reserveCapacity(64)

        for dayOffset in 0..<daysInHorizon {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
            let hourRange = preferredHours ?? workingHours
            guard let dayWorkStart = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
                  let dayWorkEnd = calendar.date(bySettingHour: min(hourRange.upperBound, workingHours.upperBound), minute: 0, second: 0, of: day) else { continue }

            let dayFloor = max(dayWorkStart, floor)
            let latestStart = dayWorkEnd.addingTimeInterval(-duration)
            if latestStart < dayFloor { continue }

            let floorSecs = dayFloor.timeIntervalSinceReferenceDate
            let snappedFloor = Date(timeIntervalSinceReferenceDate: (floorSecs / 900).rounded(.up) * 900)
            var candidate = max(dayFloor, snappedFloor)

            // Pre-compute same-day occupied count once per day — used by
            // the WeekBalance signal for every candidate on this day.
            let dayStart = calendar.startOfDay(for: day)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let sameDayCount = occupied.reduce(0) {
                $0 + (($1.start >= dayStart && $1.start < nextDay) ? 1 : 0)
            }

            while candidate <= latestStart {
                let candidateEnd = candidate.addingTimeInterval(duration)
                if candidateEnd > ceiling { break }

                let blocker = occupied.first { occ in
                    candidate < occ.end && candidateEnd > occ.start
                }
                if let blocker {
                    candidate = max(blocker.end, candidate.addingTimeInterval(900))
                    let s = candidate.timeIntervalSinceReferenceDate
                    candidate = Date(timeIntervalSinceReferenceDate: (s / 900).rounded(.up) * 900)
                    continue
                }

                let hour = calendar.component(.hour, from: candidate)
                let minute = calendar.component(.minute, from: candidate)

                // 1. Preferred-hour fit.
                let prefPenalty: Double
                if let p = preferredHours {
                    if p.contains(hour) {
                        prefPenalty = 0.0
                    } else {
                        let distance = min(abs(hour - p.lowerBound), abs(hour - p.upperBound))
                        prefPenalty = min(1.0, Double(distance) * 0.2)
                    }
                } else {
                    prefPenalty = 0.0
                }

                // 2. Energy alignment.
                let energyLevel: Double
                if let curve = preferences.personalEnergyCurve, curve.count == 24, hour >= 0, hour < 24 {
                    energyLevel = max(0, min(1, curve[hour]))
                } else {
                    let d = preferences.peakEnergyDistance(from: hour)
                    energyLevel = exp(-Double(d) * Double(d) * 0.02)
                }
                let energyMisalign = energyCost * (1.0 - energyLevel)

                // 3. Buffer gap (defaultBufferMinutes).
                var bufferPenalty = 0.0
                var gapAfter: TimeInterval = .infinity
                var nextInterval: OccupiedInterval? = nil
                for occ in occupied where occ.start >= candidateEnd {
                    nextInterval = occ
                    gapAfter = occ.start.timeIntervalSince(candidateEnd)
                    break
                }
                if requiredBufferSecs > 0 && gapAfter < requiredBufferSecs {
                    bufferPenalty = 1.0 - gapAfter / requiredBufferSecs
                }

                // 4. Deadline slack.
                var deadlineBonus = 0.0
                if let dl = deadline {
                    let slack = max(0, dl.timeIntervalSince(candidateEnd))
                    deadlineBonus = 1.0 - exp(-slack / (24.0 * 3600.0))
                }

                // 5. Focus-block continuity.
                var focusBonus = 0.0
                if isFocusBlock, idealFocusSecs > 0 {
                    let gapBefore: TimeInterval
                    if let prev = occupied.last(where: { $0.end <= candidate }) {
                        gapBefore = candidate.timeIntervalSince(prev.end)
                    } else {
                        gapBefore = .infinity
                    }
                    let combinedGap = duration + min(gapBefore, 3600) + min(gapAfter, 3600)
                    focusBonus = combinedGap >= idealFocusSecs ? 1.0 : combinedGap / idealFocusSecs
                }

                // 6. Meeting clustering.
                let clusterBonus: Double = (!isFocusBlock && clusterWindow.contains(hour)) ? 1.0 : 0.0

                // 7. Earliness tie-breaker.
                let earliness = min(1.0, max(0.0, candidate.timeIntervalSince(horizon.start) / horizonSecs))

                // 8. Context switch. Penalty when either neighbour has a
                // different context tag from the current gene. nil
                // contexts don't participate (unknown context should not
                // force a false-positive penalty).
                var contextSwitch = 0.0
                if let myCtx = geneContext {
                    if let next = nextInterval, let nCtx = next.context, nCtx != myCtx {
                        contextSwitch += 0.5
                    }
                    if let prev = occupied.last(where: { $0.end <= candidate }),
                       let pCtx = prev.context, pCtx != myCtx {
                        contextSwitch += 0.5
                    }
                }

                // 9. Pomodoro alignment. Bonus for :00 / :30 starts over
                // :15 / :45. Cheap O(1) proxy for PomodoroFit.
                let pomodoroBonus: Double = (minute == 0 || minute == 30) ? 1.0 : 0.0

                // 10. Break placement. Uses `minBreakMinutes` (cognitive
                // break) which is distinct from `defaultBufferMinutes`
                // (calendar safety). If gap to next item is below the
                // minimum break threshold, penalize.
                var breakPenalty = 0.0
                if minBreakSecs > 0 && gapAfter < minBreakSecs {
                    breakPenalty = 1.0 - gapAfter / minBreakSecs
                }

                // 11. Week balance. Avoid overstuffing a single day.
                let weekPenalty = min(1.0, Double(sameDayCount) / Double(maxPerDay))

                let cost = prefPenalty * 1.0
                         + energyMisalign * preferences.energyCurveWeight
                         + bufferPenalty * preferences.bufferWeight
                         + breakPenalty * preferences.breakWeight
                         + contextSwitch * preferences.contextSwitchWeight
                         + weekPenalty * preferences.weekBalanceWeight * 0.2
                         - deadlineBonus * preferences.deadlineWeight * 0.3
                         - focusBonus * preferences.focusBlockWeight * 0.3
                         - clusterBonus * preferences.meetingClusteringWeight * 0.2
                         - pomodoroBonus * preferences.pomodoroFitWeight * 0.1
                         + earliness * 0.1
                candidates.append((candidate, cost))
                candidate = candidate.addingTimeInterval(900)
            }
        }

        candidates.sort { $0.cost < $1.cost }
        if candidates.count > topK {
            candidates.removeLast(candidates.count - topK)
        }
        return candidates
    }

}
