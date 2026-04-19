import Foundation

// MARK: - Task Signature
//
// Coarse identity of an optimization workload, used to key caches
// (surrogate model, potentially others) across `BuboOptimizer.optimize`
// calls. Two workloads with the same signature reuse cached state;
// substantially different workloads get fresh state.
//
// Dimensions that go into the signature:
//   • The set of movable event IDs — different event populations mean
//     different fitness landscapes even if the *shape* of the schedule
//     looks similar.
//   • Duration-bucketed (5-minute) total — drift-resistant to minor
//     schedule tweaks but distinguishes 2h vs 4h workloads.
//   • Preference-weight tuple, quantized to 1-decimal place — different
//     user preferences reshape the fitness landscape and invalidate
//     transfer from prior runs.
//
// Not included (deliberately):
//   • Fixed events / participantAvailability — these change frequently
//     without semantically changing the optimization problem.
//   • RNG seed — we want runs with different seeds to reuse the
//     surrogate.
//   • Planning horizon dates — a run "today" and "tomorrow" on the same
//     event set are the same workload.

struct TaskSignature: Hashable, Sendable {
    let eventIDsHash: Int
    let totalDurationBucket: Int
    let preferenceHash: Int

    init(context: OptimizerContext) {
        var eventHasher = Hasher()
        let sortedIDs = context.movableEvents.map(\.id).sorted()
        for id in sortedIDs { eventHasher.combine(id) }
        self.eventIDsHash = eventHasher.finalize()

        let totalSeconds = context.movableEvents.reduce(0.0) { $0 + $1.duration }
        // Bucket to 5-minute resolution; 300-second bucket.
        self.totalDurationBucket = Int(totalSeconds / 300.0)

        var prefHasher = Hasher()
        let p = context.preferences
        // Quantize every weight to 1 decimal so minor slider nudges
        // don't invalidate the cache.
        prefHasher.combine(Int((p.focusBlockWeight * 10).rounded()))
        prefHasher.combine(Int((p.pomodoroFitWeight * 10).rounded()))
        prefHasher.combine(Int((p.conflictWeight * 10).rounded()))
        prefHasher.combine(Int((p.taskPlacementWeight * 10).rounded()))
        prefHasher.combine(Int((p.weekBalanceWeight * 10).rounded()))
        prefHasher.combine(Int((p.energyCurveWeight * 10).rounded()))
        prefHasher.combine(Int((p.multiPersonWeight * 10).rounded()))
        prefHasher.combine(Int((p.breakWeight * 10).rounded()))
        prefHasher.combine(Int((p.deadlineWeight * 10).rounded()))
        prefHasher.combine(Int((p.contextSwitchWeight * 10).rounded()))
        prefHasher.combine(Int((p.bufferWeight * 10).rounded()))
        prefHasher.combine(Int((p.meetingClusteringWeight * 10).rounded()))
        prefHasher.combine(Int((p.taskInclusionWeight * 10).rounded()))
        let backlogOrderWeight = p.backlogOrderWeight ?? OptimizerPreferences.defaultBacklogOrderWeight
        prefHasher.combine(Int((backlogOrderWeight * 10).rounded()))
        self.preferenceHash = prefHasher.finalize()
    }
}
