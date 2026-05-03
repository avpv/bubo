import Foundation

// MARK: - Neural Calendar Embedding (Wave 5 / item 19)
//
// Produces a fixed-length vector embedding of a schedule chromosome
// via a transformer-style pooling layer. The embedding supplements
// `TaskSignature` as a learner-cache key — two chromosomes with
// similar layout but different task IDs now map to nearby embeddings
// so learners can transfer between workloads that look alike.
//
// Architecture: per-gene feature projection → additive attention
// over the gene sequence (no positional encoding — we stamp the
// hour/day position directly as features) → mean pool → L2-norm.
// Output is a 16-dim unit vector. Weights are deterministic
// heuristics (no training), matching the GNN warm-start's stance:
// structure without training.
//
// Online feedback: contrastive-like updates via `observeSimilar(_:_:)`
// pull two embeddings together, `observeDissimilar(_:_:)` push apart.
// Gradient-free: updates happen in projection-weight space through a
// fixed-step nudging rule, not autodiff. Small magnitude, so the
// heuristic baseline is never catastrophically overwritten.

/// 16-dim L2-normalised embedding vector.
struct CalendarEmbedding: Sendable, Equatable {
    static let dimension = 16
    let values: [Double]

    init(values: [Double]) {
        precondition(values.count == Self.dimension)
        self.values = values
    }

    /// Cosine similarity to another embedding in `[-1, 1]`. Since
    /// both are unit-norm, this is just dot product.
    func similarity(to other: CalendarEmbedding) -> Double {
        var s = 0.0
        for (a, b) in zip(values, other.values) { s += a * b }
        return s
    }

    /// Euclidean distance. Since both are unit-norm and values are
    /// bounded, distance ∈ [0, 2].
    func distance(to other: CalendarEmbedding) -> Double {
        var s = 0.0
        for (a, b) in zip(values, other.values) {
            let d = a - b
            s += d * d
        }
        return sqrt(s)
    }
}

/// Embedder class with lockable adjustable weights.
final class CalendarEmbedder: @unchecked Sendable {
    private let lock = NSLock()
    /// Per-feature projection to embedding axes (10 features → 16 out).
    private var projection: [[Double]]
    /// Attention weights over the 10-dim feature (bias + 10 weights).
    private var attention: [Double]

    init() {
        // Heuristic projection + attention. Deterministic so
        // embeddings are reproducible across runs without a seed.
        projection = Self.initialProjection()
        attention = Self.initialAttention()
    }

    // MARK: - Forward

    /// Embed a schedule. Gene features are:
    ///   [hour(norm), minute(norm), duration(norm), priority,
    ///    energyCost, isFocusBlock, isIncluded,
    ///    dayOfWeek(norm), relativeDayInHorizon, bucketPosition]
    func embed(chromosome: ScheduleChromosome, context: OptimizerContext) -> CalendarEmbedding {
        let geneFeatures = Self.extractGeneFeatures(chromosome: chromosome, context: context)
        guard !geneFeatures.isEmpty else {
            return CalendarEmbedding(values: [Double](repeating: 0, count: CalendarEmbedding.dimension))
        }

        lock.lock()
        let proj = projection
        let attn = attention
        lock.unlock()

        // Attention scores and projected features in one pass.
        var scores: [Double] = []
        scores.reserveCapacity(geneFeatures.count)
        var projected: [[Double]] = []
        projected.reserveCapacity(geneFeatures.count)
        for feat in geneFeatures {
            var score = attn[0]
            for i in 0..<feat.count where i + 1 < attn.count {
                score += feat[i] * attn[i + 1]
            }
            scores.append(exp(score))
            var p = [Double](repeating: 0, count: CalendarEmbedding.dimension)
            for (row, weights) in proj.enumerated() where row < p.count {
                var s = 0.0
                for i in 0..<min(feat.count, weights.count) {
                    s += feat[i] * weights[i]
                }
                p[row] = tanh(s)
            }
            projected.append(p)
        }
        let total = scores.reduce(0, +)
        let safeTotal = total > 1e-12 ? total : 1.0
        // Weighted pool.
        var pooled = [Double](repeating: 0, count: CalendarEmbedding.dimension)
        for (g, p) in projected.enumerated() {
            let w = scores[g] / safeTotal
            for i in 0..<pooled.count { pooled[i] += w * p[i] }
        }
        // L2 normalise.
        var norm = 0.0
        for v in pooled { norm += v * v }
        norm = sqrt(max(norm, 1e-12))
        let normalized = pooled.map { $0 / norm }
        return CalendarEmbedding(values: normalized)
    }

    // MARK: - Feedback

    /// Pull two chromosomes' embeddings closer. Small step; many
    /// calls converge. Use when user treats A and B as
    /// interchangeable or chooses A after seeing B.
    func observeSimilar(
        _ a: ScheduleChromosome,
        _ b: ScheduleChromosome,
        context: OptimizerContext,
        stepSize: Double = 0.01
    ) {
        let featA = Self.extractGeneFeatures(chromosome: a, context: context)
        let featB = Self.extractGeneFeatures(chromosome: b, context: context)
        guard !featA.isEmpty || !featB.isEmpty else { return }
        nudge(features: featA, features: featB, stepSize: stepSize, direction: .closer)
    }

    /// Push two chromosomes' embeddings apart. Use when user
    /// strongly prefers one and rejects the other.
    func observeDissimilar(
        _ a: ScheduleChromosome,
        _ b: ScheduleChromosome,
        context: OptimizerContext,
        stepSize: Double = 0.01
    ) {
        let featA = Self.extractGeneFeatures(chromosome: a, context: context)
        let featB = Self.extractGeneFeatures(chromosome: b, context: context)
        guard !featA.isEmpty || !featB.isEmpty else { return }
        nudge(features: featA, features: featB, stepSize: stepSize, direction: .apart)
    }

    // MARK: - Internals

    private enum NudgeDirection { case closer, apart }

    private func nudge(
        features a: [[Double]],
        features b: [[Double]],
        stepSize: Double,
        direction: NudgeDirection
    ) {
        // Coarse heuristic: if "closer" reduce variance across the
        // feature means of the two chromosomes; if "apart" increase.
        let meanA = columnMean(a)
        let meanB = columnMean(b)
        let diff = zip(meanA, meanB).map { $0 - $1 }
        let sign: Double = (direction == .apart) ? 1.0 : -1.0
        lock.lock()
        defer { lock.unlock() }
        for row in 0..<projection.count {
            for col in 0..<projection[row].count {
                guard col < diff.count else { continue }
                projection[row][col] += sign * stepSize * diff[col]
                // Keep bounded so projection can't diverge.
                projection[row][col] = max(-3, min(3, projection[row][col]))
            }
        }
    }

    private func columnMean(_ rows: [[Double]]) -> [Double] {
        guard let width = rows.first?.count, !rows.isEmpty else { return [] }
        var sums = [Double](repeating: 0, count: width)
        for row in rows {
            for i in 0..<min(width, row.count) { sums[i] += row[i] }
        }
        return sums.map { $0 / Double(rows.count) }
    }

    // MARK: - Triplet loss training

    /// One contrastive training step using a triplet (anchor,
    /// positive, negative) of chromosomes. Margin-based loss:
    ///   L = max(0, ||emb(anchor) - emb(positive)||² -
    ///              ||emb(anchor) - emb(negative)||² + margin)
    /// Updates the projection matrix via finite-difference gradient
    /// on a random subset of weights — keeps cost per call O(W·k)
    /// where k = candidatesPerStep, avoiding full O(W) FD which
    /// would scan 160 weights per pair.
    @discardableResult
    func trainTriplet(
        anchor: ScheduleChromosome,
        positive: ScheduleChromosome,
        negative: ScheduleChromosome,
        context: OptimizerContext,
        margin: Double = 0.5,
        learningRate: Double = 0.05,
        candidatesPerStep: Int = 12
    ) -> TripletStepResult {
        let preLoss = currentTripletLoss(
            anchor: anchor, positive: positive, negative: negative,
            context: context, margin: margin
        )
        guard preLoss > 0 else {
            return TripletStepResult(preLoss: 0, postLoss: 0, weightUpdates: 0)
        }

        // Stochastic finite-difference: sample k weights, perturb
        // each by ±epsilon, take a step in the gradient direction.
        let epsilon = 1e-3
        var updates = 0

        lock.lock()
        // Snapshot dimensions; we mutate `projection` cell-by-cell
        // outside the lock between forward passes (single-thread
        // assumption during training is the safe bet).
        let rowCount = projection.count
        let colCount = projection.first?.count ?? 0
        lock.unlock()

        guard rowCount > 0, colCount > 0 else {
            return TripletStepResult(preLoss: preLoss, postLoss: preLoss, weightUpdates: 0)
        }

        let totalWeights = rowCount * colCount
        let actualCandidates = min(candidatesPerStep, totalWeights)
        var sampledIndices = Set<Int>()
        let rng = context.rng
        while sampledIndices.count < actualCandidates {
            sampledIndices.insert(rng.int(in: 0..<totalWeights))
        }

        for idx in sampledIndices {
            let r = idx / colCount
            let c = idx % colCount

            lock.lock()
            let original = projection[r][c]
            projection[r][c] = original + epsilon
            lock.unlock()
            let lossPlus = currentTripletLoss(
                anchor: anchor, positive: positive, negative: negative,
                context: context, margin: margin
            )

            lock.lock()
            projection[r][c] = original - epsilon
            lock.unlock()
            let lossMinus = currentTripletLoss(
                anchor: anchor, positive: positive, negative: negative,
                context: context, margin: margin
            )

            // Numerical gradient: descend it.
            let gradient = (lossPlus - lossMinus) / (2 * epsilon)
            lock.lock()
            let updated = original - learningRate * gradient
            projection[r][c] = max(-3, min(3, updated))
            lock.unlock()
            updates += 1
        }

        let postLoss = currentTripletLoss(
            anchor: anchor, positive: positive, negative: negative,
            context: context, margin: margin
        )
        return TripletStepResult(
            preLoss: preLoss,
            postLoss: postLoss,
            weightUpdates: updates
        )
    }

    /// Returns the triplet loss under the current weights.
    func currentTripletLoss(
        anchor: ScheduleChromosome,
        positive: ScheduleChromosome,
        negative: ScheduleChromosome,
        context: OptimizerContext,
        margin: Double = 0.5
    ) -> Double {
        let a = embed(chromosome: anchor, context: context)
        let p = embed(chromosome: positive, context: context)
        let n = embed(chromosome: negative, context: context)
        let dPos = a.distance(to: p)
        let dNeg = a.distance(to: n)
        return max(0, dPos * dPos - dNeg * dNeg + margin)
    }

    struct TripletStepResult: Sendable {
        let preLoss: Double
        let postLoss: Double
        let weightUpdates: Int
    }

    private static func extractGeneFeatures(
        chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> [[Double]] {
        let cal = context.calendar
        let horizonStart = cal.startOfDay(for: context.planningHorizon.start)
        let horizonDuration = max(1, context.planningHorizon.duration)
        var out: [[Double]] = []
        out.reserveCapacity(chromosome.genes.count)
        for (i, gene) in chromosome.genes.enumerated() {
            let hour = Double(cal.component(.hour, from: gene.startTime)) / 24.0
            let minute = Double(cal.component(.minute, from: gene.startTime)) / 60.0
            let duration = min(1.0, gene.duration / (8 * 3600))
            let dayOfWeek = Double(cal.component(.weekday, from: gene.startTime)) / 7.0
            let relativeDay = min(1, max(0,
                gene.startTime.timeIntervalSince(horizonStart) / horizonDuration
            ))
            let bucket = Double(i) / Double(max(1, chromosome.genes.count - 1))
            let vec: [Double] = [
                hour,
                minute,
                duration,
                gene.priority,
                gene.energyCost,
                gene.isFocusBlock ? 1 : 0,
                gene.isIncluded ? 1 : 0,
                dayOfWeek,
                relativeDay,
                bucket,
            ]
            out.append(vec)
        }
        return out
    }

    private static func initialProjection() -> [[Double]] {
        // 16 rows, 10 cols. Deterministic heuristic weights: we bias
        // different embedding axes toward different features so the
        // baseline embedding already spreads chromosomes meaningfully.
        var rows: [[Double]] = []
        for axis in 0..<CalendarEmbedding.dimension {
            var w = [Double](repeating: 0, count: 10)
            // Pick one primary feature per axis (cycle with offset).
            w[axis % 10] = 0.8
            // Secondary spillover for cross-feature interaction.
            w[(axis + 3) % 10] = 0.3
            w[(axis + 7) % 10] = -0.2
            rows.append(w)
        }
        return rows
    }

    private static func initialAttention() -> [Double] {
        // Bias + 10 feature weights. Priority and focus-flag get the
        // strongest attention weight so the embedding emphasises the
        // most user-meaningful genes.
        [0.1, 0.2, 0.1, 0.3, 0.6, 0.2, 0.7, 0.1, 0.1, 0.1, 0.1]
    }
}
