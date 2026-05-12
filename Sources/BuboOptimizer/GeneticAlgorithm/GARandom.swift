import Foundation

// MARK: - GARandom
//
// Seedable, deterministic random number generator for the genetic algorithm.
// Backed by SplitMix64 — a tiny, fast, high-quality generator that is cheap
// to initialize and reasonable for GA-scale sampling (not cryptographic).
//
// Why a class: every random call site inside the GA receives an `OptimizerContext`
// by value (copy-on-read). If we stored the RNG as a value type, mutations made
// by one operator (mutation, crossover, selection) would not be observed by the
// next — every call site would reset to the seed-at-construction and produce
// the same sequence. A reference-typed RNG threads a single evolving state
// through every operator, which is what we need for a deterministic run.
//
// Why SplitMix64: the stdlib's `SystemRandomNumberGenerator` is non-seedable,
// so runs cannot be reproduced for regression benchmarks. SplitMix64 is the
// reference seeder in the literature for related families (xoshiro/xoroshiro),
// passes BigCrush, and generates 64-bit words in ~1 ns.
//
// Thread safety: GARandom is explicitly **not** thread-safe. The GA runs
// concurrent offspring evaluation via `DispatchQueue.concurrentPerform`, but
// evaluation itself is pure (reads chromosome state, writes fitness only).
// Random draws happen before evaluation, during mutation/crossover/selection,
// which run sequentially per generation. The island model evolves islands in
// parallel but gives each island its own `OptimizerContext`/RNG, so there is
// no cross-island contention either.
public final class GARandom: @unchecked Sendable {
    /// The internal 64-bit state of SplitMix64. Mutated on every draw.
    private var state: UInt64

    /// The seed used to initialize this generator, for debugging and logging.
    /// When constructed without a seed, a time-based value is chosen — that
    /// value is still stored here so a failing run can be replayed by passing
    /// the same seed back in.
    public let seed: UInt64

    /// Create a generator from an explicit seed. Same seed → same sequence.
    /// The degenerate seed 0 is rewritten to SplitMix64's golden-ratio constant
    /// so the very first draw still has nonzero mix.
    public init(seed: UInt64) {
        let normalized: UInt64 = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        self.seed = normalized
        self.state = normalized
    }

    /// Create a generator with a nondeterministic seed drawn from the system.
    /// Useful for production runs where we only want reproducibility *within*
    /// a single run (e.g. to make a failing optimization replayable if we log
    /// the seed).
    convenience init() {
        var sysRng = SystemRandomNumberGenerator()
        self.init(seed: sysRng.next())
    }

    // MARK: - Core draw

    /// Advance the state one step and return a fresh 64-bit word.
    /// This is the single source of randomness; every other method derives
    /// from it so seeding one thing seeds everything.
    @inline(__always)
    public func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: - Doubles

    /// A uniformly distributed double in [0, 1). Uses the top 53 bits of the
    /// 64-bit draw so every representable double in the range is reachable.
    @inline(__always)
    public func unit() -> Double {
        Double(nextRaw() >> 11) * (1.0 / Double(1 << 53))
    }

    /// A uniform double in `range` (half-open). Matches `Double.random(in:)`
    /// semantics: `upperBound` is never returned.
    public func double(in range: Range<Double>) -> Double {
        let t = unit()
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    /// A uniform double in `range` (closed). Matches `Double.random(in:)`
    /// on a `ClosedRange`; because `unit()` only reaches values < 1.0, the
    /// upper bound itself is effectively unreachable, same as the stdlib.
    public func double(in range: ClosedRange<Double>) -> Double {
        let t = unit()
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    // MARK: - Ints

    /// A uniform int in a half-open range. Uses modulo reduction; acceptable
    /// bias for span sizes used by the GA (≤ a few thousand).
    public func int(in range: Range<Int>) -> Int {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return range.lowerBound }
        return range.lowerBound + Int(nextRaw() % UInt64(span))
    }

    /// A uniform int in a closed range. Used when the upper bound is itself
    /// a valid result (e.g. hour-of-day selection).
    public func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextRaw() % span)
    }

    // MARK: - Gaussian

    /// Cache for the spare Box–Muller sample. Marsaglia polar method produces
    /// two independent N(0,1) draws per iteration; we return the first and
    /// stash the second so the next call is O(1). `nil` means the cache is
    /// empty and the next `gaussian()` must do the rejection loop.
    private var spareGaussian: Double?

    /// Standard normal N(0, 1) sample via Marsaglia polar method. Roughly 1.27
    /// uniform draws per Gaussian draw on average; faster than classical
    /// Box–Muller because no trig calls. Needed by CMA-ES-style mutation and
    /// Gaussian shift operators.
    public func gaussian() -> Double {
        if let cached = spareGaussian {
            spareGaussian = nil
            return cached
        }
        // Rejection sampling inside the unit disk. `s` is guaranteed in (0, 1)
        // on exit so the sqrt/log are well-defined.
        var u: Double
        var v: Double
        var s: Double
        repeat {
            u = unit() * 2.0 - 1.0
            v = unit() * 2.0 - 1.0
            s = u * u + v * v
        } while s >= 1.0 || s == 0.0
        let factor = (-2.0 * log(s) / s).squareRoot()
        spareGaussian = v * factor
        return u * factor
    }

    /// Gaussian sample with configurable mean and standard deviation.
    @inline(__always)
    public func gaussian(mean: Double, stdDev: Double) -> Double {
        mean + stdDev * gaussian()
    }

    // MARK: - Convenience

    /// `true` with probability `p`. Clamped so callers don't need to validate.
    @inline(__always)
    public func bool(probability p: Double) -> Bool {
        unit() < min(max(p, 0), 1)
    }

    /// Pick a random element from an array, or nil if empty.
    public func pick<T>(_ array: [T]) -> T? {
        guard !array.isEmpty else { return nil }
        return array[int(in: 0..<array.count)]
    }

    /// In-place Fisher-Yates shuffle that uses this generator as its source.
    /// Drop-in replacement for `Array.shuffle()` in seedable code paths.
    public func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = int(in: 0...i)
            if i != j { array.swapAt(i, j) }
        }
    }

    /// Non-mutating variant; returns a shuffled copy.
    public func shuffled<T>(_ array: [T]) -> [T] {
        var copy = array
        shuffle(&copy)
        return copy
    }

    // MARK: - Derivation

    /// Derive an independent child generator. Useful for parallelizing across
    /// islands while preserving per-island determinism: given a single parent
    /// seed, each island can call `split()` in a deterministic order to get
    /// its own stream without any stream overlapping another.
    ///
    /// Implementation: jump the parent state by a large odd constant and hash
    /// the result through SplitMix64's finalizer so the child seed looks
    /// "independent" even though it's derived. This is the standard trick.
    public func split() -> GARandom {
        // Advance the parent so two consecutive splits differ.
        _ = nextRaw()
        // Mix the current state again via the SplitMix finalizer so the seed
        // we hand out is not just a successor of the parent state.
        var z = state &+ 0xDEAD_BEEF_CAFE_BABE
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        let childSeed = z ^ (z >> 31)
        return GARandom(seed: childSeed)
    }
}

// MARK: - RandomNumberGenerator conformance

/// Allows GARandom to plug into stdlib APIs that take a `RandomNumberGenerator`
/// (e.g. future callers of `Array.shuffled(using:)`). Protocol methods declared
/// `mutating` can be satisfied by classes with reference semantics — the
/// underlying state is still mutated through the class instance.
public extension GARandom: RandomNumberGenerator {
    public func next() -> UInt64 { nextRaw() }
}
