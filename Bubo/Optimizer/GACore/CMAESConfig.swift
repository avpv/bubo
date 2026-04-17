import Foundation

// MARK: - CMA-ES-lite configuration
//
// Tunables for the diagonal-covariance self-adaptive Gaussian mutation.
// Named "CMA-ES-lite" because the full algorithm maintains a dense
// covariance matrix over the continuous search variables; at the
// population sizes and gene counts we evolve (N ≤ 30 genes, pop ≤ 200),
// the dense matrix is both expensive to update and noisy. A diagonal
// approximation with the 1/5 success rule captures ~80% of the gain at
// ~5% of the complexity — well-documented in the evolutionary-strategies
// literature going back to Rechenberg (1973). We keep the constants
// centralized here so tuning is a single file change.
enum CMAESConfig {
    /// Starting standard deviation (seconds) for a freshly-constructed
    /// chromosome. 30 minutes matches the old uniform `shift` range;
    /// sigma adaptation then takes over and lets each gene settle into
    /// whatever step size fits its local landscape.
    static let initialSigmaSeconds: TimeInterval = 30 * 60

    /// Lower clamp on sigma. 1 minute — below this any shift is either
    /// lost to rounding or indistinguishable from `snap` quantization.
    static let minSigmaSeconds: TimeInterval = 60

    /// Upper clamp on sigma. 4 hours — larger shifts are effectively
    /// `moveDay`, which is a separate operator with its own niche.
    static let maxSigmaSeconds: TimeInterval = 4 * 3600

    /// Multiplier applied to sigma on an improving mutation. 1.2 is the
    /// canonical "1/5 success rule" growth factor (σ /= 0.85 on failure,
    /// σ ·= 1.2 on success keeps the long-run success rate near 1/5
    /// under Gaussian landscapes).
    static let successMultiplier: Double = 1.2

    /// Multiplier applied to sigma on a non-improving mutation. 0.85 is
    /// the reciprocal-adjacent pair to 1.2 that Rechenberg derived for
    /// the 1/5 success rule; values closer to 1 slow adaptation, values
    /// closer to 0.5 make it brittle.
    static let failureMultiplier: Double = 0.85
}
