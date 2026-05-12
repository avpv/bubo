import Foundation
import BuboDomain

// MARK: - Slot Domain

/// Precomputed set of registry slot indices that are feasible *start*
/// positions for a single movable event, taking into account the
/// event's static placement constraints and the calendar's fixed
/// events. Built once per optimization run and reused by every
/// mutation operator that samples a slot.
///
/// "Feasible" means:
///   * slot ≥ `event.earliestStart` (or `horizon.start` when absent);
///   * slot + `event.duration` ≤ `event.deadline` (when set);
///   * slot + `event.duration` fits inside the working-day window of
///     the slot's own day;
///   * the full `[slot, slot + duration)` interval does **not**
///     overlap any fixed event.
///
/// Dependency floors (`dependsOn` prerequisite end times) are **not**
/// folded in because they vary per-chromosome. Callers that need them
/// use `indices(after:registry:)` to binary-search the first domain
/// entry that satisfies the dynamic floor — O(log N) per mutation.
///
/// Why this exists: before this type, mutation operator case 1
/// (`moveDay`) called `SlotRegistry.allowedIndices` on every sample,
/// paying for a binary search over the registry plus a linear
/// working-hours check every single call. With 200 individuals × 500
/// generations × 2 children × mutation rate × genes, that's tens of
/// millions of redundant searches over the same immutable per-event
/// constraints. A precomputed domain cuts the mutation inner loop to
/// one bounded random draw.
public struct SlotDomain: Sendable {
    /// Sorted registry indices where this event can feasibly start,
    /// intersected with the fixed-event-aware filter. Empty means no
    /// feasible placement exists (tight deadline, conflicting fixed
    /// events, degenerate horizon) — callers fall back to the global
    /// registry in that case so the chromosome still carries *some*
    /// slot, even an infeasible one that repair / constraints will
    /// later penalize.
    public let indices: [Int]

    public var count: Int { indices.count }
    public var isEmpty: Bool { indices.isEmpty }

    /// First index in `indices` at position ≥ `floor`, using the
    /// registry to resolve dates. Returns the half-open slice
    /// `indices[lo..<count]`. Callers sample from this slice directly
    /// instead of rescanning the whole domain when a dependency floor
    /// is active.
    public func indices(after floor: Date, registry: SlotRegistry) -> ArraySlice<Int> {
        guard !indices.isEmpty else { return indices[0..<0] }
        var lo = 0
        var hi = indices.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let date = registry.resolvedDate(at: indices[mid])
            if let date, date < floor {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return indices[lo..<indices.count]
    }

    public static let empty = SlotDomain(indices: [])

    // MARK: - Build

    /// Build one event's slot domain against `registry` and `context`.
    /// Complexity: O(R · F) where R is the registry-index range
    /// `allowedIndices` returns for this event and F is the fixed-event
    /// count. Since this runs once per optimization run per event and
    /// both factors are small (R ≤ 500, F ≤ 50 for realistic weeks),
    /// the construction cost is paid back by the first ~100 mutations
    /// that would have recomputed the same filter dynamically.
    public static func build(
        for event: OptimizableEvent,
        registry: SlotRegistry,
        context: OptimizerContext
    ) -> SlotDomain {
        guard !registry.isEmpty, event.duration > 0 else { return .empty }

        let floor = [context.planningHorizon.start, event.earliestStart]
            .compactMap { $0 }
            .max() ?? context.planningHorizon.start

        guard let range = registry.allowedIndices(
            duration: event.duration,
            floor: floor,
            ceiling: event.deadline,
            workingHoursUpperBound: context.workingHours.upperBound
        ), !range.isEmpty else {
            return .empty
        }

        // Sort fixed events once so the overlap filter below scans a
        // monotonic cursor instead of every event per candidate.
        let fixedIntervals = context.fixedEvents
            .map { (start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }

        var result: [Int] = []
        result.reserveCapacity(range.count)
        var fixedCursor = 0
        for idx in range {
            guard let slotStart = registry.resolvedDate(at: idx) else { continue }
            let slotEnd = slotStart.addingTimeInterval(event.duration)

            // Advance the cursor past any fixed event that ends before
            // this candidate starts — those can never overlap.
            while fixedCursor < fixedIntervals.count,
                  fixedIntervals[fixedCursor].end <= slotStart {
                fixedCursor += 1
            }

            // Overlap check over the remaining fixed events whose start
            // is before `slotEnd`. A fixed event starting on or after
            // `slotEnd` can't overlap `[slotStart, slotEnd)`.
            var overlaps = false
            var probe = fixedCursor
            while probe < fixedIntervals.count,
                  fixedIntervals[probe].start < slotEnd {
                let fi = fixedIntervals[probe]
                if slotStart < fi.end && slotEnd > fi.start {
                    overlaps = true
                    break
                }
                probe += 1
            }
            if !overlaps {
                result.append(idx)
            }
        }
        return SlotDomain(indices: result)
    }
}

// MARK: - Cache Holder

/// Reference-type holder mirroring `SlotRegistryHolder` and
/// `ConflictGraphHolder`. Builds every movable event's domain once on
/// first access and serves the cached result to every value-semantic
/// copy of the context that flows through GA evaluation.
///
/// Invalidation: the holder lives for the duration of a single
/// `BuboOptimizer.optimize` call and is thrown away with the
/// context. Any workload change builds a fresh optimizer / context
/// and therefore a fresh holder — no explicit invalidation needed.
public final class SlotDomainsHolder: @unchecked Sendable {
    private var cached: [String: SlotDomain]?
    private let lock = NSLock()

    public init() {}

    /// Returns this event's precomputed domain, building every event's
    /// domain on first call. Events absent from the context's
    /// `movableEvents` (shouldn't happen in production, but defensive
    /// for tests that slip in by hand) get `.empty`.
    public func domain(for eventId: String, in context: OptimizerContext) -> SlotDomain {
        // Fast path: everything already built.
        lock.lock()
        if let cached {
            lock.unlock()
            return cached[eventId] ?? .empty
        }
        lock.unlock()

        // Build outside the lock so concurrent islands don't serialize
        // on the one-time build cost. The worst case is two islands
        // both building on first access and one result getting thrown
        // away — same pattern as `SlotRegistryHolder`.
        let registry = context.ensureSlotRegistry()
        var built: [String: SlotDomain] = [:]
        built.reserveCapacity(context.movableEvents.count)
        for event in context.movableEvents {
            built[event.id] = SlotDomain.build(for: event, registry: registry, context: context)
        }

        lock.lock()
        if cached == nil { cached = built }
        let result = cached ?? built
        lock.unlock()
        return result[eventId] ?? .empty
    }
}
