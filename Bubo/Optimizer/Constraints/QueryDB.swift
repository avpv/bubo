import Foundation
import os

// MARK: - QueryDB (dependency-tracking memoization)
//
// A small Salsa-style query database. Unlike pure hash-keyed
// memoization (`ShardedLRUCache`), `QueryDB` records *which inputs
// each query read* during evaluation. When an input changes, only
// the queries that actually touched it invalidate — unrelated
// queries keep their cached results.
//
// This is the bare-bones version of what `salsa` (Rust, used by
// rust-analyzer) and `Adapton` provide: fingerprint-based fine-
// grained invalidation, with the read set discovered automatically
// instead of hand-declared.
//
// Mental model:
//   * `setInput(key:, value:)` registers/updates a primitive input.
//   * `query(name:, build:)` runs the closure with a `Tracker` that
//     records every `read(_:)` call. The result is cached against
//     the *set of inputs touched*; subsequent calls with unchanged
//     inputs return the cached value without re-running `build`.
//   * `invalidate(key:)` (called implicitly by `setInput`) bumps the
//     input's revision counter. Cached queries are validated against
//     their recorded read-set revisions; mismatch ⇒ rebuild.
//
// Concurrency: every map access is guarded by an
// `OSAllocatedUnfairLock`. Builds run *outside* the lock so two
// threads racing on a stale query may both rebuild — the second
// store wins, both threads return logically identical results.
//
// Scope: this is scaffolding, not a full Salsa replacement. It
// supports primitive inputs and one-level queries; nested queries
// (queries that read other queries' outputs) require explicit
// re-tracking in the outer query's `build`. Future PRs can layer a
// query-of-queries dependency graph on top.

/// Opaque identifier for an input or derived value. Designed to be
/// hashed cheaply — pair `(domain, identifier)` strings work well
/// in practice ("intent.dependencies", "noEventsBefore.11").
struct QueryKey: Hashable, Sendable {
    let domain: String
    let identifier: String

    init(_ domain: String, _ identifier: String) {
        self.domain = domain
        self.identifier = identifier
    }
}

/// Tracker handed to a query's `build` closure. Calling `read(_:)`
/// records the dependency so future invalidations know which queries
/// to drop.
final class QueryTracker: Sendable {
    private let recorded: OSAllocatedUnfairLock<Set<QueryKey>>

    init() {
        self.recorded = OSAllocatedUnfairLock(initialState: [])
    }

    /// Record that the current query depends on `input`. Idempotent
    /// — multiple reads of the same input collapse to one entry.
    func read(_ input: QueryKey) {
        recorded.withLock { $0.insert(input) }
    }

    /// Read snapshot of the recorded dependency set. Called by the
    /// QueryDB after `build` returns to capture the cache entry.
    fileprivate func snapshot() -> Set<QueryKey> {
        recorded.withLock { $0 }
    }
}

/// Dependency-tracking memoization database. Generic over the value
/// type so the same DB can serve multiple query families that all
/// produce `Output`. For mixed-output workloads, instantiate one DB
/// per output type — `QueryDB<IntentGraph>`, `QueryDB<[String]>`, etc.
final class QueryDB<Output: Sendable>: Sendable {

    private struct InputState: Sendable {
        /// Monotonic revision number — bumped on every `setInput`
        /// for the same key. Cached queries record the revision
        /// they observed and re-validate against the current
        /// revision on every lookup.
        var revision: UInt64
    }

    private struct CacheEntry: Sendable {
        let value: Output
        /// Per-input revision snapshot at the time the query ran.
        /// On lookup, compare against the live `inputs` map; any
        /// mismatch means a dependency moved and the cache entry is
        /// stale.
        let observedRevisions: [QueryKey: UInt64]
    }

    private let inputs: OSAllocatedUnfairLock<[QueryKey: InputState]>
    private let cache: OSAllocatedUnfairLock<[QueryKey: CacheEntry]>

    init() {
        self.inputs = OSAllocatedUnfairLock(initialState: [:])
        self.cache = OSAllocatedUnfairLock(initialState: [:])
    }

    // MARK: Inputs

    /// Register or update a primitive input. Bumps the revision so
    /// any cached query that touched this input on its previous run
    /// sees a stale dependency on next lookup and rebuilds.
    ///
    /// Inputs are identified by `key` only; the value isn't stored
    /// here — the QueryDB doesn't know how to materialise input
    /// values, only how to track changes. Callers keep input state
    /// elsewhere (a domain model) and use `setInput` purely as the
    /// "this changed" signal.
    func setInput(_ key: QueryKey) {
        inputs.withLock { state in
            let prev = state[key]?.revision ?? 0
            state[key] = InputState(revision: prev &+ 1)
        }
    }

    /// Bulk-set inputs in a single locked section. Faster than
    /// calling `setInput` N times when registering an entire
    /// fingerprint at once.
    func setInputs<S: Sequence>(_ keys: S) where S.Element == QueryKey {
        inputs.withLock { state in
            for key in keys {
                let prev = state[key]?.revision ?? 0
                state[key] = InputState(revision: prev &+ 1)
            }
        }
    }

    // MARK: Queries

    /// Run a query, caching the result keyed by `name`. The closure
    /// receives a `QueryTracker` and must call `tracker.read(_:)`
    /// for every input it reads.
    ///
    /// Cache validation: on lookup, every recorded input's revision
    /// is compared against the current revision in the inputs map.
    /// Any mismatch (or any input missing entirely) invalidates the
    /// entry and forces a rebuild.
    ///
    /// Concurrency: the build runs outside the lock so two threads
    /// racing on a stale query may both rebuild; the second store
    /// wins. Both return logically identical values.
    func query(_ name: QueryKey, _ build: (QueryTracker) -> Output) -> Output {
        // Check cache validity first.
        if let cached = cachedIfValid(name) {
            return cached
        }

        // Miss or stale: build outside the lock.
        let tracker = QueryTracker()
        let result = build(tracker)
        let observed = tracker.snapshot()

        // Snapshot the current revisions for the touched inputs so
        // the entry self-describes its dependency state.
        let revisions = inputs.withLock { state -> [QueryKey: UInt64] in
            var out: [QueryKey: UInt64] = [:]
            for key in observed {
                out[key] = state[key]?.revision ?? 0
            }
            return out
        }

        cache.withLock { state in
            state[name] = CacheEntry(value: result, observedRevisions: revisions)
        }
        return result
    }

    /// Drop a single cached query entry. Useful when the caller
    /// knows a query's output is invalid for reasons outside the
    /// input-tracking model (e.g. an external resource changed).
    func invalidateQuery(_ name: QueryKey) {
        cache.withLock { _ = $0.removeValue(forKey: name) }
    }

    /// Drop every cached query and reset every input revision to 0.
    /// Called from session-end cleanup hooks.
    func invalidateAll() {
        cache.withLock { $0.removeAll() }
        inputs.withLock { $0.removeAll() }
    }

    // MARK: Diagnostics

    /// Number of currently cached query entries across the database.
    /// Used by tests to verify eviction/invalidation behaviour.
    var cachedCount: Int {
        cache.withLock { $0.count }
    }

    // MARK: Internals

    /// Return the cached value if every recorded dependency's
    /// revision still matches the live revision; otherwise drop the
    /// entry and return nil.
    private func cachedIfValid(_ name: QueryKey) -> Output? {
        // Read entry under the cache lock.
        let maybeEntry = cache.withLock { state in state[name] }
        guard let entry = maybeEntry else { return nil }

        // Validate the recorded revisions against the inputs map.
        // Both locks are independent, so we hold each only long
        // enough to read.
        let isValid = inputs.withLock { state -> Bool in
            for (key, observedRev) in entry.observedRevisions {
                let currentRev = state[key]?.revision ?? 0
                if observedRev != currentRev { return false }
            }
            return true
        }

        if isValid { return entry.value }
        // Stale: drop and force a rebuild on the next call.
        cache.withLock { _ = $0.removeValue(forKey: name) }
        return nil
    }
}
