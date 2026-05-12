import Foundation

// MARK: - Chance-Constrained Buffers (Wave 4 / item 5)
//
// Bubo's current `BufferObjective` + `defaultBufferMinutes` preference
// treats buffers as a fixed user knob. In reality, meeting overruns
// follow a heavy-tailed distribution: a 30-minute meeting typically
// ends at 30 minutes but has a ~15% chance of running 35-45 minutes
// and a rare chance of 60+. A fixed 5-minute buffer under-sizes for
// events that matter (client meetings, cross-team syncs) and over-
// sizes for reliable ones (1:1s, status updates).
//
// This module fits a lognormal distribution to each
// (title-canonicalized, context-tagged) event's historical actual-
// duration sample and computes a CVaR-aware buffer: the minimum
// buffer `b` such that P(actual ≤ scheduled + b) ≥ α, where α is a
// user-preference (default 0.85).
//
// The distributions update online via a streaming mean/variance
// accumulator (Welford's algorithm on log-space) so the storage cost
// is O(1) per distinct event signature. No raw samples are retained
// after aggregation — privacy-preserving by construction.

/// One event's aggregated duration distribution in log-space.
public struct DurationDistribution: Sendable {

    public init(
        count: Int,
        meanLog: Double,
        m2Log: Double
    ) {
        self.count = count
        self.meanLog = meanLog
        self.m2Log = m2Log
    }

    /// Sample count.
    public var count: Int
    /// Running mean of log(duration).
    public var meanLog: Double
    /// Running M2 statistic for Welford's variance.
    public var m2Log: Double

    /// Standard deviation of log(duration). 0 when count < 2.
    public var stdLog: Double {
        count > 1 ? sqrt(m2Log / Double(count - 1)) : 0
    }

    /// Inverse CDF of lognormal at probability `p`. Inverted via
    /// the normal inverse CDF (Beasley-Springer-Moro approximation)
    /// then exponentiated. Conservative: returns the lognormal
    /// quantile even when count = 1 (treating that as a degenerate
    /// distribution at exp(meanLog)).
    public func quantile(_ p: Double) -> TimeInterval {
        guard count > 0 else { return 0 }
        let pClamped = max(1e-4, min(1 - 1e-4, p))
        if count < 2 {
            return exp(meanLog)
        }
        let z = normalInverseCDF(pClamped)
        return exp(meanLog + z * stdLog)
    }

    /// Sample mean in linear space (median of lognormal when
    /// stdLog == 0; otherwise exp(μ + σ²/2)).
    public var mean: TimeInterval {
        let variance = stdLog * stdLog
        return exp(meanLog + variance / 2)
    }
}

/// A signature keying an event's distribution. Kept small and
/// deterministic so identical meeting series map to the same row.
public struct EventSignature: Hashable, Sendable {
    /// Case-normalised title.
    public let title: String
    /// Optional project/context tag.
    public let context: String?
    /// Bucketed scheduled duration in 15-minute increments. We keep
    /// distributions separated by scheduled duration because a
    /// "Design sync (30m)" and "Design sync (60m)" drift
    /// independently.
    public let scheduledDurationBucket: Int

    public init(title: String, context: String?, scheduledDuration: TimeInterval) {
        self.title = title.trimmingCharacters(in: .whitespaces).lowercased()
        self.context = context?.lowercased()
        self.scheduledDurationBucket = Int(scheduledDuration / 60 / 15)
    }
}

// MARK: - Store

public final class ChanceConstrainedBufferStore: @unchecked Sendable {
    public struct Configuration: Sendable {

        public init(
            quantileLevel: Double,
            minSamples: Int,
            floorMinutes: Double,
            capMinutes: Double
        ) {
            self.quantileLevel = quantileLevel
            self.minSamples = minSamples
            self.floorMinutes = floorMinutes
            self.capMinutes = capMinutes
        }

        /// Probability level (α). Buffer is sized so that P(actual
        /// finish ≤ scheduled end + buffer) ≥ α. 0.85 is a sensible
        /// default balancing conservative buffers against wasted
        /// idle time.
        public let quantileLevel: Double

        /// Minimum samples before a fitted buffer overrides the
        /// user's default. Below this we fall back to the user's
        /// configured `defaultBufferMinutes`.
        public let minSamples: Int

        /// Floor on the returned buffer (minutes). Prevents the
        /// fitter from recommending 0 when every past instance ran
        /// on time.
        public let floorMinutes: Double

        /// Cap on the returned buffer (minutes). Prevents extreme
        /// tails from producing buffers that waste half the day.
        public let capMinutes: Double

        public static let `default` = Configuration(
            quantileLevel: 0.85,
            minSamples: 5,
            floorMinutes: 2,
            capMinutes: 45
        )

        public static let aggressive = Configuration(
            quantileLevel: 0.95,
            minSamples: 3,
            floorMinutes: 5,
            capMinutes: 60
        )
    }

    public let config: Configuration
    private let lock = NSLock()
    private var distributions: [EventSignature: DurationDistribution] = [:]

    public init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Updates

    /// Record a historical (scheduled, actual) duration pair for an event.
    /// `actualDuration` is the real time the event took; `scheduledDuration`
    /// is what was on the calendar.
    public func record(
        title: String,
        context: String?,
        scheduledDuration: TimeInterval,
        actualDuration: TimeInterval
    ) {
        guard actualDuration > 0 else { return }
        let sig = EventSignature(
            title: title,
            context: context,
            scheduledDuration: scheduledDuration
        )
        let logValue = log(actualDuration)

        lock.lock()
        defer { lock.unlock() }

        var dist = distributions[sig] ?? DurationDistribution(count: 0, meanLog: 0, m2Log: 0)
        // Welford online update.
        dist.count += 1
        let delta = logValue - dist.meanLog
        dist.meanLog += delta / Double(dist.count)
        let delta2 = logValue - dist.meanLog
        dist.m2Log += delta * delta2
        distributions[sig] = dist
    }

    // MARK: - Queries

    /// Recommended buffer (minutes) for the next instance of the
    /// event. Returns `nil` when we lack enough samples — caller
    /// falls back to `preferences.defaultBufferMinutes`.
    public func recommendedBuffer(
        title: String,
        context: String?,
        scheduledDuration: TimeInterval
    ) -> Double? {
        let sig = EventSignature(
            title: title,
            context: context,
            scheduledDuration: scheduledDuration
        )
        lock.lock()
        let dist = distributions[sig]
        lock.unlock()

        guard let dist, dist.count >= config.minSamples else { return nil }

        let quantile = dist.quantile(config.quantileLevel)
        let bufferSeconds = max(0, quantile - scheduledDuration)
        let minutes = bufferSeconds / 60.0
        let clamped = max(config.floorMinutes, min(config.capMinutes, minutes))
        return clamped
    }

    /// Introspection: full distribution for a signature.
    public func distribution(
        title: String,
        context: String?,
        scheduledDuration: TimeInterval
    ) -> DurationDistribution? {
        let sig = EventSignature(
            title: title,
            context: context,
            scheduledDuration: scheduledDuration
        )
        lock.lock()
        defer { lock.unlock() }
        return distributions[sig]
    }

    public var trackedSignatureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return distributions.count
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        distributions.removeAll()
    }

    // MARK: - Persistence

    /// Snapshot every fitted distribution as flat persistence rows.
    /// Caller serialises via TrainingPersistence.
    public func exportSnapshot() -> [PersistedChanceBufferStore.Entry] {
        lock.lock()
        defer { lock.unlock() }
        return distributions.map { (sig, dist) in
            PersistedChanceBufferStore.Entry(
                titleKey: sig.title,
                contextKey: sig.context,
                scheduledDurationBucket: sig.scheduledDurationBucket,
                count: dist.count,
                meanLog: dist.meanLog,
                m2Log: dist.m2Log
            )
        }
    }

    /// Replace in-memory distributions from snapshot rows. Idempotent.
    public func importSnapshot(_ entries: [PersistedChanceBufferStore.Entry]) {
        lock.lock()
        defer { lock.unlock() }
        distributions.removeAll()
        for entry in entries {
            // EventSignature normalises title via its init; round-trip
            // through it so future record() calls hash identically.
            let scheduled = TimeInterval(entry.scheduledDurationBucket * 15 * 60)
            let sig = EventSignature(
                title: entry.titleKey,
                context: entry.contextKey,
                scheduledDuration: scheduled
            )
            distributions[sig] = DurationDistribution(
                count: entry.count,
                meanLog: entry.meanLog,
                m2Log: entry.m2Log
            )
        }
    }
}

// MARK: - Normal inverse CDF

/// Beasley-Springer-Moro (1977) rational approximation. Accurate to
/// ~7 decimal places on (0, 1); sufficient for buffer quantile
/// computations where inputs are bounded away from 0 and 1.
func normalInverseCDF(_ p: Double) -> Double {
    public let plow = 0.02425
    public let phigh = 1 - plow
    if p < plow {
        let q = sqrt(-2 * log(p))
        return rationalApprox(q)
    }
    if p <= phigh {
        let q = p - 0.5
        let r = q * q
        let num = ((((-3.969683028665376e+01 * r + 2.209460984245205e+02) * r
                    - 2.759285104469687e+02) * r + 1.383577518672690e+02) * r
                    - 3.066479806614716e+01) * r + 2.506628277459239e+00
        let den = ((((-5.447609879822406e+01 * r + 1.615858368580409e+02) * r
                    - 1.556989798598866e+02) * r + 6.680131188771972e+01) * r
                    - 1.328068155288572e+01) * r + 1.0
        return q * num / den
    }
    public let q = sqrt(-2 * log(1 - p))
    return -rationalApprox(q)
}

private func rationalApprox(_ q: Double) -> Double {
    public let num = ((((-7.784894002430293e-03 * q - 3.223964580411365e-01) * q
                - 2.400758277161838e+00) * q - 2.549732539343734e+00) * q
                + 4.374664141464968e+00) * q + 2.938163982698783e+00
    public let den = ((((7.784695709041462e-03 * q + 3.224671290700398e-01) * q
                + 2.445134137142996e+00) * q + 3.754408661907416e+00) * q + 1.0)
    return num / den
}
