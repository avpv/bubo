import Foundation
import os

// MARK: - Reachability Bitset
//
// Compact representation of a transitive reachability relation over a
// finite set of string IDs (movable events, intent nodes). Each row is
// a `[UInt64]` bitmask: word `i` covers indices `[i*64, i*64+63]`. A
// bit set at position `j` in row `from` means "`from` reaches the id
// at index `j`".
//
// Why a bitset and not the existing `[String: Set<String>]` dict?
//   * Hot path queries (does A precede B? do A and B share any
//     dependent?) become a word/bit test or a SIMD AND, instead of a
//     `Set.contains` chain that walks a hash table on every call.
//   * Set union of two reachability rows — required for incremental
//     transitive closure — collapses to a per-word `|=` over a few
//     `UInt64`s rather than `Set` insertions.
//   * Memory: one bit per (source, target) pair, so 100 events fit in
//     ~1.5 KB regardless of how dense the relation is. The dict
//     equivalent allocates a hash bucket per pair.
//
// The struct stores the index map alongside the words, so callers that
// only have string IDs (the existing public surface) can still query
// without touching the integer indices.

public struct ReachabilityBitset: Sendable {

    public init(
        indexOf: [String: Int],
        orderedIds: [String],
        count: Int,
        wordsPerRow: Int,
        words: [UInt64]
    ) {
        self.indexOf = indexOf
        self.orderedIds = orderedIds
        self.count = count
        self.wordsPerRow = wordsPerRow
        self.words = words
    }


    /// Stable index per id; `indexOf[id]` gives the bit position used
    /// in every row.
    public let indexOf: [String: Int]

    /// Inverse of `indexOf`: position → id. Stored (rather than
    /// recomputed) so `forEachReachable` doesn't re-walk the index map
    /// on every invocation.
    public let orderedIds: [String]

    /// Number of ids this bitset covers. Equal to `indexOf.count`.
    public let count: Int

    /// Words per row: `(count + 63) / 64`. Cached so callers don't
    /// recompute on every query.
    public let wordsPerRow: Int

    /// Flat bitmask storage. Row `r` occupies words
    /// `[r*wordsPerRow, (r+1)*wordsPerRow)`. Flat layout (vs.
    /// `[[UInt64]]`) keeps memory contiguous so bulk operations stay
    /// cache-friendly.
    public let words: [UInt64]

    // MARK: - Build

    /// Build a bitset from a `[id → set of ids]` reachability map.
    /// `ids` defines the canonical index ordering — pass the same
    /// ordering you use elsewhere (e.g. `eventIds`) so consumers can
    /// translate freely.
    public static func build(ids: [String], edges: [String: Set<String>]) -> ReachabilityBitset? {
        guard !ids.isEmpty else { return nil }

        var indexOf: [String: Int] = [:]
        indexOf.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { indexOf[id] = i }

        let n = ids.count
        let wpr = (n + 63) / 64
        var words = [UInt64](repeating: 0, count: n * wpr)

        for (from, targets) in edges {
            guard let row = indexOf[from] else { continue }
            let base = row * wpr
            for target in targets {
                guard let bit = indexOf[target] else { continue }
                let word = bit / 64
                let mask = UInt64(1) &<< UInt64(bit % 64)
                words[base + word] |= mask
            }
        }

        return ReachabilityBitset(
            indexOf: indexOf,
            orderedIds: ids,
            count: n,
            wordsPerRow: wpr,
            words: words
        )
    }

    // MARK: - Queries

    /// `true` iff `from` reaches `to` according to the stored relation.
    /// Returns `false` for any id not present in the index map; callers
    /// that care about the difference between "no" and "unknown" can
    /// gate on `indexOf[id] != nil` first.
    public func contains(from: String, to: String) -> Bool {
        guard let r = indexOf[from], let c = indexOf[to] else { return false }
        let word = c / 64
        let mask = UInt64(1) &<< UInt64(c % 64)
        return (words[r * wordsPerRow + word] & mask) != 0
    }

    /// Number of ids reachable from `from`. O(wordsPerRow) via
    /// `nonzeroBitCount` per word — avoids materialising the dependent
    /// set for callers that only need its size (e.g. `maxChainDepth`).
    public func reachableCount(from: String) -> Int {
        guard let r = indexOf[from] else { return 0 }
        let base = r * wordsPerRow
        var sum = 0
        for w in 0..<wordsPerRow {
            sum += words[base + w].nonzeroBitCount
        }
        return sum
    }

    /// Iterate ids reachable from `from` without allocating an
    /// intermediate `Set`. Bit-scan walks each word's set bits via
    /// `trailingZeroBitCount`, which on Apple silicon maps to a single
    /// `CTZ` instruction.
    public func forEachReachable(from: String, _ body: (String) -> Void) {
        guard let r = indexOf[from] else { return }
        let base = r * wordsPerRow
        for w in 0..<wordsPerRow {
            var word = words[base + w]
            while word != 0 {
                let tz = word.trailingZeroBitCount
                let idx = w * 64 + tz
                if idx < orderedIds.count {
                    body(orderedIds[idx])
                }
                // Clear the lowest set bit so the next iteration finds
                // the next reachable index (Brian Kernighan's trick).
                word &= word &- 1
            }
        }
    }
}

// MARK: - Lazy Holder
//
// Most consumers of `ScheduleConflictGraph` never call
// `transitivelyPrecedes(_:_:)` — they iterate `directPrecedes`
// directly or read `componentOf` and stop there. Building the bitset
// on every graph construction wastes ~N²/64 bytes per graph for
// nothing.
//
// `ReachabilityBitsetHolder` defers the build to first access. The
// holder captures the inputs (ids + edge dict) at construction time
// — both already live on the graph, so the holder is essentially
// free until someone forces the build.
//
// Concurrency: `OSAllocatedUnfairLock` guards the cached state so
// concurrent GA threads racing on first access produce one bitset
// without serializing on hot reads (cache hits don't even take the
// lock for long enough to matter).

public final class ReachabilityBitsetHolder: Sendable {

    private struct State: Sendable {
        var built: ReachabilityBitset?
        let ids: [String]
        let edges: [String: Set<String>]
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(ids: [String], edges: [String: Set<String>]) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(built: nil, ids: ids, edges: edges)
        )
    }

    /// Force the build (or return the cached bitset). Returns `nil`
    /// only when the underlying id list was empty at construction
    /// time — the empty-graph escape from `ReachabilityBitset.build`.
    public func value() -> ReachabilityBitset? {
        // Fast path: hit.
        if let cached = state.withLock({ $0.built }) {
            return cached
        }
        // We can't build under the lock without holding it for the
        // whole `ReachabilityBitset.build` call — but reading `ids`
        // and `edges` requires the lock too. Take a quick snapshot
        // so the build runs lock-free.
        let snapshot = state.withLock { (ids: $0.ids, edges: $0.edges) }
        let built = ReachabilityBitset.build(ids: snapshot.ids, edges: snapshot.edges)
        return state.withLock { current in
            if let existing = current.built {
                return existing
            }
            current.built = built
            return built
        }
    }
}
