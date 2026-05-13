import Foundation
import BuboDomain

// MARK: - Online GNN Trainer
//
// Holds mutable MessagePassingWeights and trains them from observed
// seed-vs-baseline fitness deltas via stochastic finite-difference
// gradient descent. Loss is a REINFORCE-style readout-of-top-K
// objective that propagates through every weight in message /
// update / readout matrices:
//
//   L(w) = -sign(reward) · |reward| · mean over top-K events of score
//
// Picking up fitness-weighted gradient against the top-K events that
// the *current* GNN surfaces means the trainer learns to amplify (or
// dampen) whatever structural features led to those events winning
// the priority ranking. Finite difference keeps the implementation
// autograd-free; per-observation cost stays bounded via
// `weightsSampledPerUpdate`.

public final class GNNWarmStartTrainer: @unchecked Sendable {
    public struct Configuration: Sendable {

        public init(
            learningRate: Double,
            topKConsidered: Int,
            weightCap: Double,
            weightsSampledPerUpdate: Int,
            epsilon: Double
        ) {
            self.learningRate = learningRate
            self.topKConsidered = topKConsidered
            self.weightCap = weightCap
            self.weightsSampledPerUpdate = weightsSampledPerUpdate
            self.epsilon = epsilon
        }

        /// Base learning rate for every matrix. Individual matrices
        /// can scale further via per-matrix caps if drift is
        /// observed.
        public let learningRate: Double
        /// Number of top events whose readout scores are summed into
        /// the loss objective. 3 gives a strong signal without
        /// overfitting to one noisy winner.
        public let topKConsidered: Int
        /// Absolute weight clamp; prevents runaway updates.
        public let weightCap: Double
        /// Cap on the finite-difference budget per observation.
        /// Total forward passes per observe() = 2 · weightsSampledPerUpdate + 1.
        /// 48 samples → ~97 forward passes; forward is cheap
        /// (<1 ms for 50 events, 3 rounds) so observe stays well
        /// under 100 ms on mid-range hardware.
        public let weightsSampledPerUpdate: Int
        /// Finite-difference step size.
        public let epsilon: Double

        public static let `default` = Configuration(
            learningRate: 0.02,
            topKConsidered: 3,
            weightCap: 2.5,
            weightsSampledPerUpdate: 48,
            epsilon: 1e-3
        )
    }

    public let config: Configuration
    private let lock = NSLock()
    private var weightsSnapshot: MessagePassingWeights

    public init(initialWeights: MessagePassingWeights = .heuristic, config: Configuration = .default) {
        self.weightsSnapshot = initialWeights
        self.config = config
    }

    public var weights: MessagePassingWeights {
        lock.lock(); defer { lock.unlock() }
        return weightsSnapshot
    }

    public func setWeights(_ newWeights: MessagePassingWeights) {
        lock.lock(); defer { lock.unlock() }
        weightsSnapshot = newWeights
    }

    /// Seed builder using current weights. Convenience wrapper.
    public func seedChromosome(context: OptimizerContext) -> ScheduleChromosome {
        GNNWarmStart.seedChromosome(context: context, weights: weights)
    }

    /// Observe the outcome of one GNN seed run vs. a random baseline
    /// fitness. Performs one SGD step via stochastic finite-
    /// difference gradient over message / update / readout matrices.
    public func observe(
        context: OptimizerContext,
        seedFitness: Double,
        baselineFitness: Double
    ) {
        let reward = seedFitness - baselineFitness
        guard abs(reward) > 1e-4 else { return }

        let rng = context.rng
        let signedScale = reward >= 0 ? 1.0 : -1.0
        let magnitude = abs(reward)

        // Enumerate weight addresses so sampling is uniform across
        // the three matrices. Address space:
        //   [0, M)         → message[r][c]      (M = 6·6 = 36)
        //   [M, M+U)       → update[r][c]       (U = 6·12 = 72)
        //   [M+U, M+U+R)   → readout[i]         (R = 6)
        let mRows = weightsSnapshot.message.count
        let mCols = weightsSnapshot.message.first?.count ?? 0
        let uRows = weightsSnapshot.update.count
        let uCols = weightsSnapshot.update.first?.count ?? 0
        let rLen = weightsSnapshot.readout.count
        let mSize = mRows * mCols
        let uSize = uRows * uCols
        let total = mSize + uSize + rLen
        guard total > 0 else { return }

        let k = min(config.weightsSampledPerUpdate, total)
        var sampled = Set<Int>()
        while sampled.count < k {
            sampled.insert(rng.int(in: 0..<total))
        }

        // Cache context pieces so forward passes re-use them.
        let graph = context.ensureConflictGraph()
        let baseFeatures = GNNWarmStart.featuresFor(context: context)
        guard !baseFeatures.isEmpty else { return }

        for address in sampled {
            let (matrix, row, col) = decodeAddress(
                address,
                mRows: mRows, mCols: mCols,
                uRows: uRows, uCols: uCols,
                rLen: rLen,
                mSize: mSize, uSize: uSize
            )
            lock.lock()
            let original = readWeight(matrix: matrix, row: row, col: col)
            writeWeight(original + config.epsilon, matrix: matrix, row: row, col: col)
            let snapshotPlus = weightsSnapshot
            writeWeight(original - config.epsilon, matrix: matrix, row: row, col: col)
            let snapshotMinus = weightsSnapshot
            writeWeight(original, matrix: matrix, row: row, col: col)
            lock.unlock()

            let lossPlus = computeLoss(
                features: baseFeatures,
                graph: graph,
                weights: snapshotPlus,
                signedScale: signedScale,
                magnitude: magnitude
            )
            let lossMinus = computeLoss(
                features: baseFeatures,
                graph: graph,
                weights: snapshotMinus,
                signedScale: signedScale,
                magnitude: magnitude
            )

            let gradient = (lossPlus - lossMinus) / (2 * config.epsilon)
            let step = config.learningRate * gradient
            lock.lock()
            let newValue = max(
                -config.weightCap,
                min(config.weightCap, original - step)
            )
            writeWeight(newValue, matrix: matrix, row: row, col: col)
            lock.unlock()
        }
    }

    public func reset(to initial: MessagePassingWeights = .heuristic) {
        lock.lock(); defer { lock.unlock() }
        weightsSnapshot = initial
    }

    // MARK: - Internals

    private enum WeightMatrix { case message, update, readout }

    private func decodeAddress(
        _ address: Int,
        mRows: Int, mCols: Int,
        uRows: Int, uCols: Int,
        rLen: Int,
        mSize: Int, uSize: Int
    ) -> (WeightMatrix, Int, Int) {
        if address < mSize {
            return (.message, address / mCols, address % mCols)
        }
        let rel1 = address - mSize
        if rel1 < uSize {
            return (.update, rel1 / uCols, rel1 % uCols)
        }
        return (.readout, 0, address - mSize - uSize)
    }

    private func readWeight(matrix: WeightMatrix, row: Int, col: Int) -> Double {
        switch matrix {
        case .message: return weightsSnapshot.message[row][col]
        case .update:  return weightsSnapshot.update[row][col]
        case .readout: return weightsSnapshot.readout[col]
        }
    }

    private func writeWeight(_ value: Double, matrix: WeightMatrix, row: Int, col: Int) {
        switch matrix {
        case .message: weightsSnapshot.message[row][col] = value
        case .update:  weightsSnapshot.update[row][col] = value
        case .readout: weightsSnapshot.readout[col] = value
        }
    }

    /// Loss function: REINFORCE-style negative reward-weighted sum
    /// of top-K readouts. Lower loss = higher-scoring top-K events
    /// when reward is positive.
    private func computeLoss(
        features: [String: GNNNodeFeatures],
        graph: ScheduleConflictGraph,
        weights: MessagePassingWeights,
        signedScale: Double,
        magnitude: Double
    ) -> Double {
        // Run the forward pass under the provided weights.
        let scores = forward(features: features, graph: graph, weights: weights)
        let topK = scores.sorted { $0.value > $1.value }
            .prefix(config.topKConsidered)
        guard !topK.isEmpty else { return 0 }
        let sum = topK.reduce(0.0) { $0 + $1.value }
        let mean = sum / Double(topK.count)
        return -signedScale * magnitude * mean
    }

    /// Forward pass mirroring GNNWarmStart.priorityScores but
    /// accepting explicit weights so the trainer can probe
    /// perturbed variants without mutating shared state.
    private func forward(
        features: [String: GNNNodeFeatures],
        graph: ScheduleConflictGraph,
        weights: MessagePassingWeights,
        rounds: Int = 3
    ) -> [String: Double] {
        var hidden: [String: [Double]] = features.mapValues { $0.asArray }
        for _ in 0..<rounds {
            hidden = stepLocal(hidden: hidden, adjacency: graph.directPrecedes, weights: weights)
        }
        var out: [String: Double] = [:]
        out.reserveCapacity(hidden.count)
        for (id, h) in hidden {
            var s = 0.0
            for (v, k) in zip(h, weights.readout) { s += v * k }
            out[id] = s
        }
        return out
    }

    private func stepLocal(
        hidden: [String: [Double]],
        adjacency: [String: Set<String>],
        weights: MessagePassingWeights
    ) -> [String: [Double]] {
        var aggregated: [String: [Double]] = [:]
        aggregated.reserveCapacity(hidden.count)
        for (id, h) in hidden {
            let neighbours = adjacency[id] ?? []
            if neighbours.isEmpty {
                aggregated[id] = [Double](repeating: 0, count: h.count)
            } else {
                var acc = [Double](repeating: 0, count: h.count)
                for n in neighbours {
                    guard let nh = hidden[n] else { continue }
                    let msg = matVec(weights.message, nh)
                    for j in 0..<acc.count where j < msg.count { acc[j] += msg[j] }
                }
                let scale = 1.0 / Double(neighbours.count)
                for j in 0..<acc.count { acc[j] *= scale }
                aggregated[id] = acc
            }
        }
        var next: [String: [Double]] = [:]
        next.reserveCapacity(hidden.count)
        for (id, h) in hidden {
            let agg = aggregated[id] ?? [Double](repeating: 0, count: h.count)
            let concat = h + agg
            let updated = matVec(weights.update, concat).map { tanh($0) }
            next[id] = updated
        }
        return next
    }

    private func matVec(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in
            var s = 0.0
            for i in 0..<min(row.count, v.count) { s += row[i] * v[i] }
            return s
        }
    }
}
