import Foundation

// MARK: - CMA-ME Emitter (Wave 2 / п.9)
//
// Covariance Matrix Adaptation — MAP-Elites (Fontaine et al., 2020)
// replaces the uniform-perturbation emitter inside a QD loop with a
// CMA-ES-like Gaussian whose mean + covariance matrix adapt based on
// whether emitted children improve the archive.
//
// For schedule chromosomes the "decision space" is the per-gene start-
// time offset relative to each gene's own current placement, measured
// in minutes and clipped to the working-hour window of its day. This
// is a continuous search space — well-suited to a multivariate
// Gaussian — without having to encode the whole (eventId, slot,
// include-flag) tuple.
//
// The emitter is lean: a diagonal covariance to avoid O(N²) per sample
// on large genomes, with per-gene step size adaptation from CMA-ES's
// "1/5 success rule". Full covariance is overkill for scheduling —
// the cross-gene correlations that matter (precedence, context
// switches) are better captured by the structural operators in the
// main GA, not by a dense matrix.

/// One CMA-ME emitter bound to a specific template chromosome. The
/// template fixes gene count / eventId positions; samples are offset
/// vectors of the same length.
final class CMAMEEmitter: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Initial per-gene standard deviation (minutes). 30 is a
        /// sensible starting point: one Pomodoro round's worth of
        /// wiggle per sample.
        let initialSigmaMinutes: Double

        /// Minimum allowed sigma; under this the emitter is in
        /// "converged" mode — further samples will duplicate.
        /// Triggers a reset by the host.
        let sigmaMin: Double

        /// Sigma floor/ceiling to keep adaptation numerically stable.
        let sigmaCap: Double

        /// Success rate target for the 1/5 rule. Canonical value is
        /// 0.2 (one in five samples should improve); for QD we
        /// slightly lower it because improvement of a niche is
        /// rarer than improvement of a scalar.
        let targetSuccessRate: Double

        /// How fast sigma reacts to success-rate drift. Higher =
        /// faster adaptation, more oscillation.
        let sigmaAdaptationRate: Double

        static let `default` = Configuration(
            initialSigmaMinutes: 30.0,
            sigmaMin: 3.0,
            sigmaCap: 240.0,
            targetSuccessRate: 0.15,
            sigmaAdaptationRate: 0.1
        )
    }

    let config: Configuration
    let template: ScheduleChromosome
    private let lock = NSLock()

    /// Per-gene standard deviation (minutes). Starts uniform at
    /// `initialSigmaMinutes`; grows for productive axes, shrinks for
    /// over-explored ones.
    private var sigma: [Double]

    /// Per-gene mean offset (minutes). Starts at zero; drifts toward
    /// successful directions.
    private var mean: [Double]

    /// Rolling success indicator: +1 per successful emit, -1 per
    /// unsuccessful. Drives the 1/5 rule.
    private var successBank: Double = 0
    private var samplesSinceReset: Int = 0

    init(
        template: ScheduleChromosome,
        config: Configuration = .default
    ) {
        self.template = template
        self.config = config
        let n = template.genes.count
        self.sigma = [Double](repeating: config.initialSigmaMinutes, count: n)
        self.mean = [Double](repeating: 0, count: n)
    }

    // MARK: - Emit

    /// Sample one child chromosome. The child inherits template's
    /// gene structure (eventIds, durations, metadata) with start-
    /// times perturbed by a Gaussian in minutes space, then clipped
    /// to the working-hour window.
    func emit(context: OptimizerContext) -> ScheduleChromosome {
        lock.lock()
        let meanSnapshot = self.mean
        let sigmaSnapshot = self.sigma
        lock.unlock()
        let rng = context.rng
        let cal = context.calendar
        let slotRegistry = context.ensureSlotRegistry()

        var newGenes: [ScheduleGene] = []
        newGenes.reserveCapacity(template.genes.count)
        for (i, gene) in template.genes.enumerated() {
            let mu = i < meanSnapshot.count ? meanSnapshot[i] : 0
            let s = i < sigmaSnapshot.count ? sigmaSnapshot[i] : config.initialSigmaMinutes
            let offsetMinutes = rng.gaussian(mean: mu, stdDev: s)
            let shifted = gene.startTime.addingTimeInterval(offsetMinutes * 60)
            let clipped = clipToWorkingHours(
                candidate: shifted,
                calendar: cal,
                workingHours: context.workingHours
            )
            newGenes.append(gene.withSlot(nearest: clipped, registry: slotRegistry))
        }
        var child = ScheduleChromosome(genes: newGenes, needsEvaluation: true)
        child.repair(context: context)
        return child
    }

    /// Batch emit. Useful for quick "top up the archive" calls.
    func emit(batchSize: Int, context: OptimizerContext) -> [ScheduleChromosome] {
        (0..<batchSize).map { _ in emit(context: context) }
    }

    // MARK: - Feedback

    /// Tell the emitter whether the latest batch of samples produced
    /// archive improvements. `successCount` out of `totalSamples`.
    /// Drives the sigma / mean update.
    ///
    /// Passing `improvementDirections` (the offsets from template
    /// that yielded improvements) lets the emitter shift its mean
    /// toward the improving region — a simple rank-μ update.
    func observe(
        successCount: Int,
        totalSamples: Int,
        improvementDirections: [[Double]] = []
    ) {
        guard totalSamples > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        let successRate = Double(successCount) / Double(totalSamples)
        let delta = successRate - config.targetSuccessRate
        // Multiplicative sigma update — 1/5 rule variant. Exp(delta)
        // so sigma scales multiplicatively and stays positive.
        let factor = exp(config.sigmaAdaptationRate * delta)
        for i in sigma.indices {
            sigma[i] = max(config.sigmaMin, min(config.sigmaCap, sigma[i] * factor))
        }

        // Mean update: blend toward the centroid of improvement
        // directions with a conservative learning rate. Slow enough
        // that a single lucky sample can't derail the emitter.
        if !improvementDirections.isEmpty {
            let learningRate = 0.3
            let dim = mean.count
            var centroid = [Double](repeating: 0, count: dim)
            for dir in improvementDirections {
                for i in 0..<min(dim, dir.count) {
                    centroid[i] += dir[i]
                }
            }
            for i in 0..<dim { centroid[i] /= Double(improvementDirections.count) }
            for i in 0..<dim {
                mean[i] = (1 - learningRate) * mean[i] + learningRate * centroid[i]
            }
        }

        successBank += Double(successCount) - Double(totalSamples - successCount)
        samplesSinceReset += totalSamples
    }

    /// Is the emitter stuck (sigma at floor across every gene)?
    /// A true return signals the host to reset mean/sigma (e.g. by
    /// rebinding to a fresh template).
    var hasConverged: Bool {
        lock.lock(); defer { lock.unlock() }
        return sigma.allSatisfy { $0 <= config.sigmaMin * 1.05 }
    }

    /// Reset to initial state. Host re-binds the template by
    /// constructing a fresh emitter; this just resets the
    /// adaptation state of the current one.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        let n = template.genes.count
        sigma = [Double](repeating: config.initialSigmaMinutes, count: n)
        mean = [Double](repeating: 0, count: n)
        successBank = 0
        samplesSinceReset = 0
    }

    // MARK: - Diagnostics

    struct Telemetry: Sendable {
        let meanSigma: Double
        let minSigma: Double
        let maxSigma: Double
        let samplesObserved: Int
        let successBank: Double
    }

    var telemetry: Telemetry {
        lock.lock(); defer { lock.unlock() }
        let mean = sigma.reduce(0, +) / Double(max(1, sigma.count))
        return Telemetry(
            meanSigma: mean,
            minSigma: sigma.min() ?? 0,
            maxSigma: sigma.max() ?? 0,
            samplesObserved: samplesSinceReset,
            successBank: successBank
        )
    }

    // MARK: - Internals

    private func clipToWorkingHours(
        candidate: Date,
        calendar: Calendar,
        workingHours: ClosedRange<Int>
    ) -> Date {
        let day = calendar.startOfDay(for: candidate)
        guard let minStart = calendar.date(
            bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day
        ), let maxStart = calendar.date(
            bySettingHour: max(workingHours.lowerBound, workingHours.upperBound - 1),
            minute: 0, second: 0, of: day
        ) else {
            return candidate
        }
        if candidate < minStart { return minStart }
        if candidate > maxStart { return maxStart }
        return candidate
    }
}
