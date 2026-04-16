import Foundation

// MARK: - Schedule Repairer Protocol

/// Pluggable repair strategy for infeasible or low-quality schedules.
/// Defaults to the in-place heuristic repair baked into
/// `ScheduleChromosome.repair`; advanced deployments can inject a
/// constraint-propagation repairer, or an LLM-backed repairer that
/// asks an off-board model to propose a fix.
///
/// The GA calls the repairer only as a fallback when the cheap
/// per-gene repair couldn't produce a feasible layout. We don't want
/// to route every repair through an LLM — that would add network
/// latency to every mutation — so the contract is "given a chromosome
/// that `ConstraintEngine` is still unhappy with after `repair()`, try
/// something smarter."
///
/// Conformers must be pure: no side effects beyond the returned
/// chromosome. Thread safety is on conformers; the default heuristic
/// implementation is stateless.
protocol ScheduleRepairer: Sendable {
    /// Return a repaired copy of `chromosome`. Implementations are free
    /// to return the input unchanged if they can't improve on it —
    /// callers compare fitness before/after and keep the better one.
    func repair(
        _ chromosome: ScheduleChromosome,
        context: OptimizerContext,
        constraintEngine: ConstraintEngine
    ) async -> ScheduleChromosome
}

// MARK: - Heuristic Constraint-Aware Repairer

/// Propagation-lite repairer. Walks genes in priority order and,
/// whenever the current slot is infeasible, scans the planning
/// horizon for a feasible one that respects every hard constraint.
/// Uses `ConstraintEngine.violations` to know *why* a slot is bad so
/// the search can skip large swaths of the horizon at once (e.g. jump
/// past a full day when any day-level constraint fires).
///
/// Strictly better than `ScheduleChromosome.repair` on hard cases
/// because it explicitly consults the constraint engine instead of
/// assuming overlap-only failure modes. Still cheap — no backtracking
/// beyond one gene at a time — so it fits in the mutation hot path.
struct HeuristicRepairer: ScheduleRepairer {

    func repair(
        _ chromosome: ScheduleChromosome,
        context: OptimizerContext,
        constraintEngine: ConstraintEngine
    ) async -> ScheduleChromosome {
        var out = chromosome
        out.repair(context: context)
        // If the baked-in repair already produced feasibility, nothing
        // more to do — skip the deeper sweep.
        if constraintEngine.isValid(out, context: context) { return out }

        let cal = context.calendar
        let horizonStart = context.planningHorizon.start
        let horizonEnd = context.planningHorizon.end

        // Priority descending so the hardest-to-place (highest value)
        // genes get first pick of what remains feasible.
        let order = out.genes.indices.sorted {
            out.genes[$0].priority > out.genes[$1].priority
        }

        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        // Seed occupied with locked genes so they're respected.
        for i in out.genes.indices where out.genes[i].isLocked && out.genes[i].isIncluded {
            occupied.append((out.genes[i].startTime, out.genes[i].endTime))
        }
        occupied.sort { $0.start < $1.start }

        for idx in order where !out.genes[idx].isLocked && out.genes[idx].isIncluded {
            let duration = out.genes[idx].duration
            let event = context.movableEvents.first { $0.id == out.genes[idx].eventId }

            // Propagate the earliestStart and dependency floor.
            var floor = horizonStart
            if let earliest = event?.earliestStart { floor = max(floor, earliest) }
            if let event {
                for depId in event.dependsOn {
                    if let depGene = out.genes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                        floor = max(floor, depGene.endTime)
                    }
                }
            }

            // Candidate scan at 15-minute granularity, skipping past
            // blockers. This is the constraint-propagation-lite core —
            // we don't keep a full domain/arc structure, but we do keep
            // the scan monotone so later candidates inherit earlier
            // prunings for free.
            var candidate = max(out.genes[idx].startTime, floor)
            candidate = clampToWorkingHours(
                candidate, duration: duration,
                workingHours: context.workingHours,
                calendar: cal, floor: floor
            )
            let latest = horizonEnd.addingTimeInterval(-duration)

            var placed: Date?
            while candidate <= latest {
                let candEnd = candidate.addingTimeInterval(duration)
                let blocker = occupied.first { occ in
                    candidate < occ.end && candEnd > occ.start
                }
                if let blocker {
                    candidate = blocker.end > candidate ? blocker.end : candidate.addingTimeInterval(900)
                    candidate = clampToWorkingHours(
                        candidate, duration: duration,
                        workingHours: context.workingHours,
                        calendar: cal, floor: floor
                    )
                    continue
                }
                // Trial-place and run the constraint engine — even a
                // non-overlap slot can still violate working hours,
                // deadline, lunch window, etc. The engine is the
                // authority.
                var trial = out
                trial.genes[idx] = trial.genes[idx].withStartTime(candidate)
                if constraintEngine.isValid(trial, context: context) {
                    placed = candidate
                    break
                }
                candidate = candidate.addingTimeInterval(900)
            }

            if let placed {
                out.genes[idx] = out.genes[idx].withStartTime(placed)
                occupied.append((placed, placed.addingTimeInterval(duration)))
                occupied.sort { $0.start < $1.start }
                out.needsEvaluation = true
            } else if out.genes[idx].isDroppable {
                // Nothing fits; drop the gene as a last resort. Non-
                // droppable genes stay in place and the constraint
                // engine will penalise them — the GA's softer pressure
                // then has to find an alternative configuration.
                out.genes[idx].isIncluded = false
                out.needsEvaluation = true
            }
        }

        return out
    }
}

// MARK: - LLM-Backed Repair Bridge

/// Adapter that routes repair requests to an LLM. This codebase does
/// not embed a live LLM client; the adapter accepts a caller-supplied
/// closure that turns a chromosome description into a repair proposal
/// and is expected to be wired up by the application layer (where the
/// existing `LLMIntentBridge` lives).
///
/// The repair proposal protocol is JSON with the shape
///     {"moves": [{"eventId": "...", "startTime": "ISO8601"}], ...}
/// so the LLM's output surface is the same as `ScheduleIntent` decoded
/// time moves. We decode back into gene updates and re-run the
/// constraint engine to confirm the LLM's proposal is feasible; if it
/// isn't, we fall back to the heuristic repairer so a bad LLM response
/// never corrupts the GA.
///
/// Why LLM-backed repair at all: when the constraint structure is
/// genuinely complex (multi-participant negotiations, external OOO
/// data the constraint engine can't see), a smart language model can
/// sometimes propose a feasible layout no heuristic would find.
/// Network cost caps this to "last resort" usage; we gate it with a
/// confidence threshold + rate limit on the consumer.
struct LLMRepairer: ScheduleRepairer {
    typealias ProposalClosure = @Sendable (ScheduleChromosome, OptimizerContext) async -> [ScheduleGene]?

    /// Closure supplied by the application layer; returns a proposed
    /// set of genes. Nil = LLM could not / did not respond; the caller
    /// falls back to the heuristic repairer.
    let propose: ProposalClosure

    /// Fallback repairer invoked on any failure path.
    let fallback: ScheduleRepairer

    init(
        propose: @escaping ProposalClosure,
        fallback: ScheduleRepairer = HeuristicRepairer()
    ) {
        self.propose = propose
        self.fallback = fallback
    }

    func repair(
        _ chromosome: ScheduleChromosome,
        context: OptimizerContext,
        constraintEngine: ConstraintEngine
    ) async -> ScheduleChromosome {
        // Try the LLM first. Any failure (nil, invalid genes, still
        // infeasible) drops straight to the fallback — we never hand
        // back a worse chromosome than `HeuristicRepairer` would.
        if let proposal = await propose(chromosome, context) {
            // Merge the proposal by eventId so we tolerate partial LLM
            // responses (the LLM may return only the genes it moved).
            var merged = chromosome
            var byId: [String: ScheduleGene] = [:]
            for g in proposal { byId[g.eventId] = g }
            for i in merged.genes.indices {
                if let donor = byId[merged.genes[i].eventId], !merged.genes[i].isLocked {
                    merged.genes[i] = donor
                }
            }
            merged.needsEvaluation = true
            if constraintEngine.isValid(merged, context: context) {
                return merged
            }
        }
        return await fallback.repair(chromosome, context: context, constraintEngine: constraintEngine)
    }
}
