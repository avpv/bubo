import Foundation

// MARK: - Day Compactness Objective

/// Rewards placing multiple same-day movable tasks close together so
/// the day ends with contiguous free time at the edges rather than
/// scattered dead-time holes between tasks.
///
/// Defined per day as `taskMinutes / spanMinutes`, where:
///   * `taskMinutes` = total duration of movable tasks on the day;
///   * `spanMinutes` = time from the first movable task's start to
///      the last movable task's end.
///
/// Three tasks of 1 hour each placed back-to-back at 09:00 → 12:00
/// produce `3h / 3h = 1.0`. The same three tasks scattered at 09:00,
/// 13:00, and 17:00 produce `3h / 9h ≈ 0.33` — the objective pulls
/// toward the first layout without caring where on the day the
/// block sits (TaskPlacement's "earliness" term handles that).
///
/// Fixed events are deliberately **not** counted: they already
/// fragment the day, and the user can't do anything about their
/// placement. Scoring them would make a busy-meeting day look
/// "compact" by accident.
///
/// Days with zero or one movable task score 1.0 (trivially compact).
/// Days with no movable tasks at all are skipped in the combine step
/// via the day-partitioned default — their absence shouldn't drag
/// the aggregate.
///
/// Plays complementarily with:
///   * **Buffer**, which rewards adequate gaps between adjacent pairs.
///     A buffer-friendly schedule keeps a few minutes between tasks;
///     compactness keeps that few-minute gap from becoming an hour.
///   * **BreakPlacement**, which demands real breaks at specific
///     points. Compactness doesn't fight breaks — it pulls
///     consecutive work blocks together, the break constraint pushes
///     mandatory gaps at its own locations.
///   * **ContextSwitch**, which clusters same-context tasks.
///     Compactness is context-agnostic; they reinforce each other on
///     matched workloads and stay independent on mixed ones.
struct DayCompactnessObjective: DayPartitionedObjective {
    let name = "DayCompactness"
    var weight: Double

    init(weight: Double = 0.5) {
        self.weight = weight
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        combinePerDay(evaluatePerDay(chromosome: chromosome, context: context))
    }

    func evaluatePerDay(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [Date: Double] {
        let cal = context.calendar
        var movablesByDay: [Date: [(start: Date, end: Date)]] = [:]
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            movablesByDay[day, default: []].append((gene.startTime, gene.endTime))
        }
        var perDay: [Date: Double] = [:]
        perDay.reserveCapacity(movablesByDay.count)
        for (day, events) in movablesByDay {
            perDay[day] = Self.score(events: events)
        }
        return perDay
    }

    func evaluateOneDay(
        day: Date,
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Double {
        let cal = context.calendar
        var events: [(start: Date, end: Date)] = []
        for gene in chromosome.genes where gene.isIncluded && cal.startOfDay(for: gene.startTime) == day {
            events.append((gene.startTime, gene.endTime))
        }
        return Self.score(events: events)
    }

    private static func score(events: [(start: Date, end: Date)]) -> Double {
        guard events.count >= 2 else { return 1.0 }
        let sorted = events.sorted { $0.start < $1.start }
        let taskMinutes = sorted.reduce(0.0) { acc, ev in
            acc + ev.end.timeIntervalSince(ev.start) / 60.0
        }
        guard taskMinutes > 0 else { return 1.0 }
        let firstStart = sorted.first!.start
        let lastEnd = sorted.last!.end
        let spanMinutes = lastEnd.timeIntervalSince(firstStart) / 60.0
        guard spanMinutes > 0 else { return 1.0 }
        // Ratio clamped to [0, 1]; compact layouts → ~1, spread ones → low.
        return max(0, min(1, taskMinutes / spanMinutes))
    }
}
