import Foundation

// MARK: - Parallel Evaluator

/// Swift Concurrency-based parallel evaluator used as a drop-in
/// replacement for `DispatchQueue.concurrentPerform` in the GA hot
/// paths. The legacy GCD path stays available (no behavioural change)
/// so anyone relying on the old sync-blocking call can keep it; new
/// code paths are expected to route through here.
///
/// Benefits over `concurrentPerform`:
///   • Plays correctly with Swift 6 strict concurrency — each task is
///     an isolated `TaskGroup` child rather than a closure smuggled
///     across actor boundaries.
///   • Cooperative with structured concurrency: parent task
///     cancellation propagates to every evaluator task automatically,
///     which `concurrentPerform` can't do.
///   • Consistent with the rest of the codebase's async model (the
///     BuboOptimizer entry points are already `async`).
///
/// The API is structurally identical to `concurrentPerform` so the
/// swap is a local rewrite. Callers that must stay sync wrap with
/// `withCheckedContinuation` — we don't provide the wrapper because
/// callers within the GA can already be async as of the SOTA
/// augmentations.
enum ParallelEvaluator {

    /// Run `body` for each index in `0..<count` concurrently. Caller
    /// is responsible for ensuring the closure is safe to call from
    /// multiple tasks at once (pure fitness evaluation is safe
    /// because it reads immutable context and writes only the passed-
    /// in offspring slot).
    ///
    /// Cap concurrency via `maxConcurrency` to avoid oversubscription
    /// when this is invoked from inside an already-parallel context
    /// (e.g. per-island evolution). Pass `0` for unlimited.
    static func run(
        count: Int,
        maxConcurrency: Int = 0,
        body: @Sendable @escaping (Int) -> Void
    ) async {
        guard count > 0 else { return }

        let limit: Int
        if maxConcurrency > 0 {
            limit = min(count, maxConcurrency)
        } else {
            limit = count
        }

        await withTaskGroup(of: Void.self) { group in
            var started = 0
            var next = 0

            // Prime the pool up to the concurrency limit.
            while started < limit {
                let idx = next
                next += 1
                group.addTask { body(idx) }
                started += 1
            }

            // Drain one-in-one-out so we never exceed `limit` live tasks.
            // `TaskGroup.next()` returns after any task finishes; we
            // replace it with the next pending index.
            while next < count {
                _ = await group.next()
                let idx = next
                next += 1
                group.addTask { body(idx) }
            }

            // Wait for the tail.
            await group.waitForAll()
        }
    }

    /// Sync bridge for call sites that can't propagate `async` yet.
    /// Blocks the current thread until every task finishes — use
    /// sparingly, it defeats the point of structured concurrency.
    static func runSync(
        count: Int,
        maxConcurrency: Int = 0,
        body: @Sendable @escaping (Int) -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await run(count: count, maxConcurrency: maxConcurrency, body: body)
            semaphore.signal()
        }
        semaphore.wait()
    }
}
