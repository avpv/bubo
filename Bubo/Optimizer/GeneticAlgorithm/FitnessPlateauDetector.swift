import Foundation

// MARK: - Fitness Plateau Detector

/// Rolling-window convergence detector. Pushes the current-generation
/// best fitness; reports `isPlateau == true` once the window is full
/// and the relative standard deviation across it falls below the
/// configured threshold.
///
/// Why this exists: the legacy "stale generations since last
/// improvement > patience" counter is sensitive to cache-driven
/// jitter. When a chromosome re-enters the population via elitism +
/// crossover and its cached fitness is recomputed with 1e-6-level
/// floating-point noise, the counter resets to zero even though
/// nothing meaningful changed. On a 4-task workload that landed on
/// its optimum at generation 0, this effect kept the counter
/// bouncing between 0 and 5 for the full `patience=25` window and
/// terminated only when the wallclock timeout fired.
///
/// The window-based detector instead asks "has the best fitness
/// actually moved in any meaningful way across the last N
/// generations?" — cache jitter averages out inside the window, so
/// the relative stddev stays microscopic and the detector fires
/// reliably even when the scalar-counter approach wouldn't.
///
/// The detector is advisory: callers combine it with the
/// conventional counter for backward compatibility with CHC-restart
/// triggers that condition on "stagnation" as a soft signal rather
/// than a termination command.
struct FitnessPlateauDetector {
    /// Maximum number of most-recent generation scores the window
    /// keeps. Beyond this, the oldest entries are discarded so the
    /// detector only ever sees the "recent" history.
    let capacity: Int

    /// Termination threshold on relative standard deviation
    /// (`stddev / mean`). 1e-4 means "the spread across the window
    /// is under 0.01% of the mean" — tight enough to distinguish
    /// cache jitter from genuine slow improvement.
    let relativeStddevThreshold: Double

    private var window: [Double] = []

    init(capacity: Int, relativeStddevThreshold: Double = 1e-4) {
        self.capacity = max(2, capacity)
        self.relativeStddevThreshold = max(0, relativeStddevThreshold)
        self.window.reserveCapacity(self.capacity)
    }

    /// Append this generation's best fitness to the rolling window.
    /// Oldest entries drop off once capacity is exceeded so subsequent
    /// `isPlateau` reads reflect only the most-recent `capacity`
    /// generations.
    mutating func push(_ fitness: Double) {
        window.append(fitness)
        if window.count > capacity {
            window.removeFirst(window.count - capacity)
        }
    }

    /// True when the window is full and the relative standard
    /// deviation across it is below `relativeStddevThreshold`.
    /// Returns false while the window is still filling (fewer than
    /// `capacity` pushes) — otherwise a freshly-started GA would
    /// report plateau on generation 2 before any real search
    /// happened.
    var isPlateau: Bool {
        guard window.count >= capacity else { return false }
        let mean = window.reduce(0, +) / Double(window.count)
        // Degenerate: zero-mean window means the GA is producing
        // near-zero fitness (infeasible only) — no signal yet.
        guard mean > 1e-9 else { return false }
        var sumSq = 0.0
        for value in window {
            let delta = value - mean
            sumSq += delta * delta
        }
        let variance = sumSq / Double(window.count)
        let stddev = variance.squareRoot()
        return (stddev / abs(mean)) < relativeStddevThreshold
    }

    /// Drop every recorded value. Used by CHC restart paths so the
    /// detector doesn't immediately re-trigger on the pre-restart
    /// plateau.
    mutating func reset() {
        window.removeAll(keepingCapacity: true)
    }

    /// Current window occupancy — exposed for diagnostic logging.
    var filledCount: Int { window.count }
}
