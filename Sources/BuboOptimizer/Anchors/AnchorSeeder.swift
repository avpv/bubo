import Foundation

// MARK: - Anchor seeding (CP-SAT + greedy fallback, one decision site)
//
// Every optimizer entry point that kicks off a fresh GA run needs a
// single seed chromosome that (a) primes `IslandModelGA.anchorSeed`
// for population replication, and (b) slots into the initial seed
// list as the feasibility-optimal individual. `AnchorSeeder` is the
// only place where that decision is made. Previously the choice was
// inlined at two call sites (`BuboOptimizer.optimize` and, implicitly
// via missing CP-SAT wiring, `IncrementalReoptimizer.reoptimize`) —
// which let them drift: only the first-run path ever saw CP-SAT,
// reopt silently fell back to greedy without logging why.
//
// The seeder also attaches a typed `AnchorSource` so the caller can
// emit structured telemetry without re-deriving the provenance. The
// same decision table governs both cold-start (`optimize`) and
// warm-start (`reoptimize`) paths.

public struct AnchorSeeder {

    /// Which optimization flow is requesting the anchor. `.reopt`
    /// carries the current schedule as a warm-start hint for
    /// CP-SAT; `.firstRun` kicks off cold.
    public enum Mode: Sendable {
        case firstRun
        case reopt(currentSchedule: [ScheduleGene])
    }

    /// Gate flags, decoupled from `SchedulingFeatureToggles` so the
    /// seeder is usable from the reopt path (which holds a plain
    /// `OptimizerContext`, not a `BuboOptimizer`).
    public struct Gates: Sendable {

        public init(
            cpsatEnabled: Bool,
            windowThreshold: Int
        ) {
            self.cpsatEnabled = cpsatEnabled
            self.windowThreshold = windowThreshold
        }

        /// Honour `SchedulingFeatureToggles.useCPSATSeed`.
        let cpsatEnabled: Bool
        /// Honour `OptimizerContext.cpSATWindowThreshold`.
        let windowThreshold: Int

        static let enabled = Gates(cpsatEnabled: true, windowThreshold: 20)
        static let disabled = Gates(cpsatEnabled: false, windowThreshold: 0)
    }

    public let gates: Gates

    public init(gates: Gates = .enabled) {
        self.gates = gates
    }

    /// Produce an anchor chromosome together with its provenance.
    /// Never returns nil: a greedy fallback is always available (it
    /// is feasibility-by-construction on our domain), so the caller
    /// can rely on the anchor unconditionally.
    public func makeAnchor(
        context: OptimizerContext,
        mode: Mode
    ) -> (chromosome: ScheduleChromosome, source: AnchorSource) {
        // 1. Feature flag off → greedy, no CP-SAT attempted.
        guard gates.cpsatEnabled, context.cpSATRepairer != nil else {
            return (
                ScheduleChromosome.greedy(context: context),
                .greedy(reason: .disabled)
            )
        }

        // 2. Workload past the window → CP-SAT's DFS budget is
        //    mis-sized for the instance. Skip without starting the
        //    clock; the GA's polish/refine presets already scale by
        //    difficulty and don't need a solver result here.
        if context.movableEvents.count > gates.windowThreshold {
            return (
                ScheduleChromosome.greedy(context: context),
                .greedy(reason: .windowExceeded)
            )
        }

        // 3. Try CP-SAT. `cpSeeded` returns nil on timeout /
        //    infeasibility; both collapse to a greedy fallback, but
        //    the reason tag distinguishes them so telemetry can
        //    separate "solver ran out of budget" from "sub-problem
        //    has no feasible assignment at all".
        let warmStart: [ScheduleGene]?
        let warmStarted: Bool
        switch mode {
        case .firstRun:
            warmStart = nil
            warmStarted = false
        case let .reopt(currentSchedule):
            warmStart = currentSchedule
            warmStarted = !currentSchedule.isEmpty
        }

        let started = Date()
        let seed = ScheduleChromosome.cpSeeded(
            context: context,
            warmStart: warmStart
        )
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)

        if let seed {
            return (seed, .cpsat(durationMs: durationMs, warmStarted: warmStarted))
        }

        // `cpSeeded` returns nil for two reasons:
        //   • non-droppable event with an empty slot domain
        //     (infeasible at the input level), or
        //   • solver produced a partial assignment that didn't
        //     cover every variable (timeout).
        // We can't distinguish them from the nil alone without
        // plumbing a richer return type; the distinction costs one
        // cheap domain check, so do it here rather than muddying
        // the seeder's public signature.
        let reason: GreedyReason = hasInfeasibleDomain(context: context)
            ? .infeasible
            : .timeout
        return (
            ScheduleChromosome.greedy(context: context),
            .greedy(reason: reason)
        )
    }

    /// True when any non-droppable movable event has an empty
    /// feasible-slot domain — i.e. the sub-problem is structurally
    /// infeasible and CP-SAT would have returned nil regardless of
    /// budget. Same check `cpSeeded` performs when deciding whether
    /// to bail early.
    private func hasInfeasibleDomain(context: OptimizerContext) -> Bool {
        for event in context.movableEvents where !event.isDroppable {
            if context.ensureSlotDomain(for: event.id).isEmpty {
                return true
            }
        }
        return false
    }
}
