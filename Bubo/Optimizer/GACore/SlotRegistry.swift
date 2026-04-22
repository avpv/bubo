import Foundation

// MARK: - Slot Registry

/// Precomputed list of every valid 15-min start time in the planning
/// horizon — the GA's discrete search space.
///
/// A slot is a `Date` that satisfies:
///   * falls on a day in `preferences.workingDays`;
///   * sits inside `workingHours` for its day;
///   * lies inside `planningHorizon`;
///   * does **not** overlap a fixed-event block (those minutes are
///     unusable regardless of duration, so excluding them here keeps
///     the slot count honest for mutation sampling).
///
/// The registry is per-context — `OptimizerContext.slotRegistry` builds
/// it lazily on first read and every gene-placing code path consults
/// the same cached instance. Genes reference slots by `Int` index
/// (`ScheduleGene.slotIndex`); the `startTime: Date` field stays in sync
/// via `resolvedDate(at:)` so existing fitness/constraint/UI readers
/// keep working unchanged during the migration.
///
/// Why discrete indices: the continuous `Date` search space is
/// ~40,320 15-min slots/week × 60 seconds each — 2.4 million candidate
/// timestamps. With a registry that admits only valid slots (≈300 for
/// a typical 5-day, 10h/day week, minus fixed events), the search
/// space collapses by four orders of magnitude and every hard
/// constraint on placement becomes infeasible-to-represent rather
/// than merely infeasible-to-evaluate.
struct SlotRegistry: Sendable {
    /// Every valid slot start, sorted ascending. Genes index into this
    /// array via `ScheduleGene.slotIndex`. An out-of-range index reads
    /// as "no slot" via the guarded accessors.
    let slots: [Date]

    /// Calendar captured at build time so binary-search / day-of-week
    /// queries stay consistent even if the caller is later handed a
    /// different calendar for its own purposes.
    let calendar: Calendar

    /// Grid stride in seconds. Auto-detected from the workload at
    /// `build(from:)` time: 15 minutes when every fixed event and
    /// every movable duration is a multiple of 15 (the common case),
    /// 5 minutes otherwise. Finer detection (1-2 minutes) is
    /// deliberately clamped up to 5 because per-minute resolution
    /// triples the search space for no measurable scheduling gain.
    ///
    /// Operators that need "±30 minutes in slot steps" read
    /// `stridesForMinutes(30)` and stop caring whether the underlying
    /// grid is 15 or 5 — the math scales proportionally.
    let stride: TimeInterval

    /// Commonly-needed default. Used as a parameter default for
    /// helpers that can't easily access a registry (e.g. free-slot
    /// finders called before registry build). Matches the legacy
    /// hardcoded 15-min step.
    static let defaultStride: TimeInterval = 15 * 60

    /// Number of slots that covers `minutes` on the current stride,
    /// rounded up. `stridesForMinutes(30)` on a 15-min grid returns 2;
    /// on a 5-min grid returns 6 — keeps a "±30 min shift" mutation
    /// from collapsing to "±10 min" just because the grid got finer.
    func stridesForMinutes(_ minutes: Int) -> Int {
        max(1, Int(ceil(Double(minutes) * 60.0 / stride)))
    }

    var count: Int { slots.count }
    var isEmpty: Bool { slots.isEmpty }

    // MARK: - Lookup

    /// Returns the `Date` at `index`, or `nil` when the index is out
    /// of range. Callers should be prepared for nil because a
    /// chromosome migrated from an older build can carry a slot
    /// index that no longer exists in a rebuilt registry (different
    /// fixed events, shorter horizon, etc.).
    func resolvedDate(at index: Int) -> Date? {
        guard index >= 0, index < slots.count else { return nil }
        return slots[index]
    }

    /// Index of the slot closest to `date` in the registry. Uses binary
    /// search so the lookup stays O(log n) even on dense registries.
    /// Returns `nil` when the registry is empty; otherwise returns an
    /// in-range index, preferring the earlier of two equidistant slots
    /// so tie-breaking is deterministic.
    func nearestIndex(to date: Date) -> Int? {
        guard !slots.isEmpty else { return nil }
        let target = date.timeIntervalSinceReferenceDate
        var lo = 0
        var hi = slots.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if slots[mid].timeIntervalSinceReferenceDate < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // `lo` now points at the first slot ≥ target; compare with its
        // predecessor to pick the closer of the two.
        if lo > 0 {
            let below = slots[lo - 1].timeIntervalSinceReferenceDate
            let above = slots[lo].timeIntervalSinceReferenceDate
            return (target - below) <= (above - target) ? lo - 1 : lo
        }
        return lo
    }

    /// Clamp `index` into the registry's valid range. Used by operators
    /// that add/subtract a delta — after a shift the raw index can land
    /// outside `[0, count)` and the caller would rather be snapped back
    /// to a boundary than return `nil`.
    func clamped(_ index: Int) -> Int {
        guard !slots.isEmpty else { return 0 }
        return min(max(0, index), slots.count - 1)
    }

    // MARK: - Per-event filtering

    /// Returns the inclusive index range of slots where an event of
    /// `duration` with `floor`/`ceiling` bounds could feasibly *start*.
    /// A slot is eligible when:
    ///   * its start ≥ floor;
    ///   * its start + duration ≤ ceiling (when ceiling is non-nil);
    ///   * the same day's working-hours end is ≥ start + duration,
    ///     i.e. the event fits inside that working day.
    ///
    /// Returns `nil` when no slot fits (caller falls back to random /
    /// accepts infeasibility).
    func allowedIndices(
        duration: TimeInterval,
        floor: Date,
        ceiling: Date?,
        workingHoursUpperBound: Int
    ) -> Range<Int>? {
        guard !slots.isEmpty else { return nil }
        guard duration > 0 else { return 0..<slots.count }

        // Lower bound: first slot whose start ≥ floor. Binary search
        // for the floor and walk forward until we land on a slot that
        // leaves room for the full duration on its day.
        guard let floorIdx = nearestIndex(to: floor) else { return nil }
        var lower = floorIdx
        if slots[lower] < floor { lower += 1 }
        if lower >= slots.count { return nil }

        // Upper bound: last slot whose start + duration ≤ ceiling.
        let ceilingDate = ceiling ?? slots.last!
        var upper = slots.count - 1
        while upper >= lower {
            if slots[upper].addingTimeInterval(duration) <= ceilingDate {
                // Also require the event finish by the working-hours
                // end of its day — a 2h event starting at 17:30 on a
                // 9–18 day would otherwise overshoot.
                let day = calendar.startOfDay(for: slots[upper])
                if let dayEnd = calendar.date(bySettingHour: workingHoursUpperBound, minute: 0, second: 0, of: day),
                   slots[upper].addingTimeInterval(duration) <= dayEnd {
                    break
                }
            }
            upper -= 1
        }
        if upper < lower { return nil }
        return lower..<(upper + 1)
    }

    // MARK: - Build

    /// Precompute the valid-slot list for `context`. Fixed-event
    /// conflicts are filtered here so mutation samplers don't need
    /// per-slot overlap checks — the list already excludes anything
    /// a fixed block covers.
    ///
    /// Complexity: O(D × H × log F) where D is horizon days, H is
    /// working-hour slots per day, F is fixed-event count. For a
    /// typical 7-day horizon with 10h/day and 20 fixed events this
    /// is ~280 × log 20 ≈ 1200 comparisons. Built once per context
    /// and cached — the hot-path cost is effectively zero.
    static func build(from context: OptimizerContext) -> SlotRegistry {
        let cal = context.calendar
        let prefs = context.preferences
        let horizon = context.planningHorizon
        let workingDays = prefs.workingDays

        // Auto-detect grid stride before building. Fine-grid only
        // when the workload has non-15-aligned fixed events or
        // durations — otherwise stay on 15-min to keep the search
        // space compact.
        let stride = autoDetectStride(for: context)

        let horizonStartDay = cal.startOfDay(for: horizon.start)
        let horizonLastDay = cal.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (cal.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        // Sort fixed intervals once so the overlap check is
        // monotonic-pointer rather than quadratic.
        let fixedIntervals = context.fixedEvents
            .map { (start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
        var fixedCursor = 0

        // Estimate capacity: days × (hours × slots-per-hour). On a
        // 5-min stride that's ×12, on 15-min ×4. Overshoots slightly
        // because some slots are filtered by fixed events; harmless.
        let hoursPerDay = context.workingHours.upperBound - context.workingHours.lowerBound
        let slotsPerHour = Int(ceil(3600.0 / stride))
        var slots: [Date] = []
        slots.reserveCapacity(max(16, daysInHorizon * hoursPerDay * slotsPerHour))

        for dayOffset in 0..<daysInHorizon {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
            if !workingDays.contains(cal.component(.weekday, from: day)) { continue }

            guard let dayLower = cal.date(bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let dayUpper = cal.date(bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day)
            else { continue }

            // Respect horizon edges on the boundary days — horizon.start
            // may land mid-afternoon, horizon.end may land before work
            // ends.
            let dayWorkStart = max(dayLower, horizon.start)
            let dayWorkEnd = min(dayUpper, horizon.end)
            if dayWorkStart >= dayWorkEnd { continue }

            // Snap the lower edge up to a 15-min boundary so the grid
            // is globally consistent.
            let lowerSecs = dayWorkStart.timeIntervalSinceReferenceDate
            let snappedLowerSecs = (lowerSecs / stride).rounded(.up) * stride
            var candidate = Date(timeIntervalSinceReferenceDate: snappedLowerSecs)

            while candidate < dayWorkEnd {
                // Advance fixedCursor to the first interval that could
                // possibly contain or follow `candidate`. Since fixed
                // intervals and candidates both walk forward in time,
                // we never have to step the cursor back.
                while fixedCursor < fixedIntervals.count,
                      fixedIntervals[fixedCursor].end <= candidate {
                    fixedCursor += 1
                }
                // Drop slots that start inside a fixed block. Slots
                // that merely end inside one are kept — duration-based
                // feasibility is the gene-specific filter, not the
                // registry's job.
                var insideFixed = false
                var walk = fixedCursor
                while walk < fixedIntervals.count,
                      fixedIntervals[walk].start < candidate.addingTimeInterval(stride) {
                    let interval = fixedIntervals[walk]
                    if candidate >= interval.start && candidate < interval.end {
                        insideFixed = true
                        break
                    }
                    walk += 1
                }
                if !insideFixed {
                    slots.append(candidate)
                }
                candidate = candidate.addingTimeInterval(stride)
            }
        }

        return SlotRegistry(slots: slots, calendar: cal, stride: stride)
    }

    // MARK: - Stride auto-detection

    /// Returns the grid stride the registry should use for this
    /// workload, expressed in seconds. Scans fixed-event start/end
    /// timestamps and movable-event earliestStart / deadline /
    /// duration, extracts their minute-of-hour offsets, and takes
    /// the GCD. The two tiers we actually return:
    ///
    ///   * `15 × 60` (default) — every observed minute offset is a
    ///     multiple of 15. Covers the overwhelming majority of
    ///     real calendars where meetings live on quarter-hour
    ///     boundaries and tasks are specified in 30 / 60 / 90 min.
    ///   * `5 × 60` — anything else. A fixed event at 15:05, a
    ///     23-minute duration, a 17:37 deadline — any of those
    ///     drops the grid to 5-min resolution so the solver can
    ///     actually fit tasks into the gaps those non-aligned
    ///     events leave.
    ///
    /// We don't go below 5 minutes because triple-precision grid
    /// (1-min / per-second) inflates the search space without
    /// measurably improving placement quality on human-paced
    /// calendars — every integer-minute stride gets rounded up
    /// to 5.
    static func autoDetectStride(for context: OptimizerContext) -> TimeInterval {
        let cal = context.calendar
        var nonZeroOffsets: [Int] = []
        nonZeroOffsets.reserveCapacity(
            context.fixedEvents.count * 2 + context.movableEvents.count * 3
        )

        func captureMinute(_ date: Date) {
            let m = cal.component(.minute, from: date)
            if m != 0 { nonZeroOffsets.append(m) }
        }

        for ev in context.fixedEvents {
            captureMinute(ev.startDate)
            captureMinute(ev.endDate)
        }
        for ev in context.movableEvents {
            if let es = ev.earliestStart { captureMinute(es) }
            if let dl = ev.deadline { captureMinute(dl) }
            // Duration's minute-of-hour tail. A 90-min task has tail 30
            // (multiple of 15); a 23-min task has tail 23 (not a
            // multiple of 15 and not 5 either — drops grid to 5).
            let tail = Int((ev.duration / 60).rounded()) % 60
            if tail != 0 { nonZeroOffsets.append(tail) }
        }

        guard !nonZeroOffsets.isEmpty else {
            // Everything aligned to the hour — 15-min grid is fine.
            return defaultStride
        }

        // Include 60 in the GCD pool so the hour boundary stays
        // representable — without it a workload that's all at :15
        // would produce GCD = 15 correctly, but all at :20 would
        // produce GCD = 20 and we want to fall through to the
        // 5-min floor instead.
        var g = 60
        for m in nonZeroOffsets {
            g = gcd(g, m)
            if g <= 1 { break }
        }

        // Clamp: { ≥ 15 → 15-min grid, otherwise → 5-min grid }.
        // The narrow range {5, 15} keeps mutation deltas /
        // domain-size scaling predictable. Intermediate tiers
        // (7, 10, 12) were considered but don't help in practice —
        // user-facing schedules rarely have that much irregularity.
        return g >= 15 ? defaultStride : 5 * 60
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b > 0 { (a, b) = (b, a % b) }
        return a
    }
}

// MARK: - Empty registry sentinel

extension SlotRegistry {
    /// Empty registry for tests or early-init paths where no context
    /// is available. `nearestIndex` returns nil, `allowedIndices`
    /// returns nil, every lookup is a no-op — callers handle that
    /// path by falling through to legacy `startTime`-based logic.
    static let empty = SlotRegistry(slots: [], calendar: .current, stride: defaultStride)
}

// MARK: - Cache holder

/// Reference-type holder that caches a built `SlotRegistry` across the
/// many value-semantic copies of `OptimizerContext` that flow through
/// GA evaluation. Every chromosome on the population shares one
/// registry — build cost is paid exactly once per run, same pattern
/// as `ConflictGraphHolder`.
///
/// Thread safety: `NSLock` guards the lazy build so concurrent
/// islands requesting the registry before it's populated don't race
/// on each other's partial state.
final class SlotRegistryHolder: @unchecked Sendable {
    private var cached: SlotRegistry?
    private let lock = NSLock()

    init(preloaded: SlotRegistry? = nil) {
        self.cached = preloaded
    }

    /// Returns the cached registry, building it on first request using
    /// the supplied context. Subsequent calls return the same instance
    /// regardless of which `OptimizerContext` copy asks — the registry
    /// is determined by fixed events + horizon + preferences, all of
    /// which are immutable for the life of an optimization run.
    func get(for context: OptimizerContext) -> SlotRegistry {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = SlotRegistry.build(from: context)

        lock.lock()
        if cached == nil { cached = built }
        let result = cached ?? built
        lock.unlock()
        return result
    }

    /// Cheap test/inject path: seed the cache without running `build`.
    /// Used by unit tests that construct a registry by hand and want
    /// the context to serve that specific instance.
    func preload(_ registry: SlotRegistry) {
        lock.lock()
        cached = registry
        lock.unlock()
    }
}
