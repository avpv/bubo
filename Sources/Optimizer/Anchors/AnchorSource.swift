import Foundation

// MARK: - Anchor provenance
//
// Every `optimize()` and every `reoptimize()` run produces a single
// seed chromosome that both (a) primes the island populations via
// `IslandModelGA.anchorSeed` and (b) lands in the initial seed list
// as the feasibility-optimal starting point. `AnchorSource` is the
// typed record of where that anchor came from so downstream
// telemetry can distinguish a CP-SAT success from each distinct
// greedy-fallback reason (flag off, workload too large, solver
// timeout, infeasible sub-problem, reopt path without warm-start
// budget). The previous string-valued tag collapsed all four
// greedy reasons into one bucket — fine for "did CP-SAT fire?" but
// useless for "why didn't it?", which is the question that actually
// drives tuning.

public enum AnchorSource: Sendable, Equatable {
    /// CP-SAT produced a complete feasibility-optimal assignment.
    /// `warmStarted` is true when the solver was primed with a
    /// caller-supplied hint (reopt path) rather than a cold start.
    case cpsat(durationMs: Int, warmStarted: Bool)

    /// Greedy construction ran instead of CP-SAT. `reason` records
    /// why CP-SAT did not deliver so the choice is attributable in
    /// logs and regressions.
    case greedy(reason: GreedyReason)
}

public enum GreedyReason: String, Sendable {
    /// `SchedulingFeatureToggles.useCPSATSeed` was off for this run.
    case disabled

    /// Workload exceeded `OptimizerContext.cpSATWindowThreshold`.
    /// CP-SAT's DFS budget is sized for small/medium weeks; past
    /// the window the greedy start is strictly cheaper and lands
    /// the GA in the same polish regime.
    case windowExceeded

    /// CP-SAT returned a partial / timed-out assignment that
    /// `cpSeeded` rejected as worse than a greedy start.
    case timeout

    /// The sub-problem was infeasible at the input level — a
    /// non-droppable event with an empty slot domain, an empty
    /// workload, or missing repairer on the context.
    case infeasible

    /// Reopt path chose not to invoke CP-SAT (e.g. warm-start
    /// disabled for a preview-style call). Distinct from
    /// `.disabled` because `useCPSATSeed` may still be on
    /// globally — this is a per-call policy decision.
    case reoptFallback
}

public extension AnchorSource {
    /// Compact label for structured logs. Stable across versions —
    /// aggregations in log-analysis pipelines key on this string.
    public var logLabel: String {
        switch self {
        case let .cpsat(_, warmStarted):
            return warmStarted ? "cpsat+warm" : "cpsat"
        case let .greedy(reason):
            return "greedy(\(reason.rawValue))"
        }
    }

    /// Solver wall-time in milliseconds when the anchor came from
    /// CP-SAT; zero on a greedy fallback.
    public var cpsatDurationMs: Int {
        if case let .cpsat(ms, _) = self { return ms }
        return 0
    }

    /// True when the anchor was produced by CP-SAT (cold or warm).
    public var isCPSAT: Bool {
        if case .cpsat = self { return true }
        return false
    }
}
