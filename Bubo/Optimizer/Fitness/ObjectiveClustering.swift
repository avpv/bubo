import Foundation

// MARK: - Objective Correlation Clustering (Wave 2 / item 6)
//
// 14 objectives is many-objective territory. Raw decomposition (MOEA/D,
// NSGA-III) allocates search effort uniformly across those 14 axes,
// even though several are typically near-collinear in practice
// (ContextSwitch + MeetingClustering + Buffer tend to move together,
// Deadline + TaskInclusion track priority, etc).
//
// This module computes the per-generation correlation matrix between
// objective scores on the active population and greedily clusters
// correlated objectives into aggregate "meta-objectives". Downstream
// decomposition (MOEA/D weight vectors, reference points) can work on
// 3–5 aggregates instead of 14 raw axes — faster convergence, better
// Pareto-front coverage.
//
// The clustering is online and non-destructive: the raw objective
// scores remain available, a `ClusterAssignment` snapshot just
// provides an aggregation plan the caller may apply. Re-clustering
// typically happens every ~25 generations so the aggregates track
// the population's current trade-off regime.

/// A cluster of co-varying objectives.
struct ObjectiveCluster: Sendable {
    /// Human-readable identifier; we concatenate member names.
    let label: String
    /// Member objective names (non-empty).
    let members: [String]
    /// Average Pearson correlation between members within the cluster.
    /// Higher = tighter cluster. Clusters with one member report 1.0.
    let cohesion: Double
}

/// The outcome of a clustering pass.
struct ClusterAssignment: Sendable {
    /// Cluster objects in a stable (sorted by first member's name) order.
    let clusters: [ObjectiveCluster]

    /// Map from original objective name → cluster index. Fast lookup
    /// for consumers that aggregate per-objective scores.
    let clusterIndexOf: [String: Int]

    /// Aggregate a per-objective score vector into a per-cluster
    /// vector. Each cluster's score is the mean of its members'
    /// scores — simple, preserves the [0, 1] range, and is what
    /// MOEA/D weight vectors need.
    func aggregate(objectives: [String: Double]) -> [Double] {
        var sums = [Double](repeating: 0, count: clusters.count)
        var counts = [Int](repeating: 0, count: clusters.count)
        for (name, value) in objectives {
            guard let idx = clusterIndexOf[name] else { continue }
            sums[idx] += value
            counts[idx] += 1
        }
        return zip(sums, counts).map { total, n in
            n > 0 ? total / Double(n) : 0
        }
    }
}

/// Online correlation-based clusterer. Stateless operation is the
/// `cluster(...)` static; the class form maintains an EMA of the
/// correlation matrix across calls so the clustering is stable even
/// when a single generation has a noisy correlation signal.
final class ObjectiveCorrelationClusterer: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Correlation threshold above which two objectives merge.
        /// 0.6 is a common sociological/psychometric default and
        /// empirically produces 3–5 clusters on our 14 objectives.
        let mergeThreshold: Double

        /// EMA decay for the persistent correlation matrix.
        /// 0 = no memory (each call is independent), 1 = never update.
        /// Default 0.6 blends today's signal with yesterday's.
        let emaDecay: Double

        /// Minimum samples before clustering is trusted. Below this
        /// the clusterer returns the trivial "every objective is its
        /// own cluster" assignment.
        let warmupSamples: Int

        static let `default` = Configuration(
            mergeThreshold: 0.6,
            emaDecay: 0.6,
            warmupSamples: 20
        )
    }

    let config: Configuration

    private let lock = NSLock()
    private var names: [String] = []
    private var correlation: [[Double]] = []
    private var samplesSeen: Int = 0

    init(config: Configuration = .default) {
        self.config = config
    }

    /// Feed a single generation's objective scores. `rows[i][j]` is
    /// the score of individual `i` on objective `names[j]`.
    func observe(names: [String], rows: [[Double]]) {
        guard !rows.isEmpty, !names.isEmpty else { return }
        let thisCorr = Self.pearsonMatrix(rows: rows)
        lock.lock()
        defer { lock.unlock() }
        if self.names != names {
            self.names = names
            self.correlation = thisCorr
        } else {
            let a = config.emaDecay
            for i in correlation.indices {
                for j in correlation[i].indices {
                    correlation[i][j] = a * correlation[i][j] + (1 - a) * thisCorr[i][j]
                }
            }
        }
        samplesSeen += rows.count
    }

    /// Current clustering assignment. Returns the trivial one-cluster-
    /// per-objective assignment until `warmupSamples` is reached.
    func currentClustering() -> ClusterAssignment {
        lock.lock()
        defer { lock.unlock() }
        if samplesSeen < config.warmupSamples || names.isEmpty {
            return trivialAssignment(names: names)
        }
        return Self.clusterByThreshold(
            names: names,
            correlation: correlation,
            threshold: config.mergeThreshold
        )
    }

    // MARK: - Stateless API

    /// One-shot cluster of a raw population matrix. Skips the EMA
    /// and returns the clustering for just these rows.
    static func cluster(
        names: [String],
        rows: [[Double]],
        threshold: Double = 0.6
    ) -> ClusterAssignment {
        guard !rows.isEmpty, !names.isEmpty else {
            return ClusterAssignment(clusters: [], clusterIndexOf: [:])
        }
        let corr = pearsonMatrix(rows: rows)
        return clusterByThreshold(names: names, correlation: corr, threshold: threshold)
    }

    // MARK: - Internals

    /// Pearson correlation matrix over the columns (objectives).
    /// Uses the population formula since we're clustering population-
    /// level behaviour, not inferring a sample's generative process.
    static func pearsonMatrix(rows: [[Double]]) -> [[Double]] {
        guard let m = rows.first?.count, m > 0 else { return [] }
        let n = rows.count
        var means = [Double](repeating: 0, count: m)
        for row in rows {
            for j in 0..<min(m, row.count) { means[j] += row[j] }
        }
        for j in 0..<m { means[j] /= Double(n) }

        // Centred columns, followed by dot products.
        var centered = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for (i, row) in rows.enumerated() {
            for j in 0..<min(m, row.count) {
                centered[i][j] = row[j] - means[j]
            }
        }
        var norms = [Double](repeating: 0, count: m)
        for i in 0..<n {
            for j in 0..<m {
                norms[j] += centered[i][j] * centered[i][j]
            }
        }
        for j in 0..<m { norms[j] = sqrt(max(norms[j], 1e-12)) }

        var corr = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for a in 0..<m {
            for b in a..<m {
                if a == b {
                    corr[a][b] = 1.0
                    continue
                }
                var dot = 0.0
                for i in 0..<n { dot += centered[i][a] * centered[i][b] }
                let denom = norms[a] * norms[b]
                let c = denom > 1e-9 ? dot / denom : 0
                corr[a][b] = c
                corr[b][a] = c
            }
        }
        return corr
    }

    /// Simple greedy agglomerative clustering by correlation: merge
    /// the highest-correlation pair into a cluster, recompute the
    /// cluster–cluster correlation as the mean of member pair
    /// correlations, repeat until no pair exceeds the threshold.
    ///
    /// The standard "UPGMA" flavour — adequate here because m is
    /// tiny (14) and the clusters tend to be few and well-separated.
    static func clusterByThreshold(
        names: [String],
        correlation: [[Double]],
        threshold: Double
    ) -> ClusterAssignment {
        let m = names.count
        precondition(correlation.count == m)

        // Start: one cluster per objective.
        var memberships: [[Int]] = (0..<m).map { [$0] }

        while true {
            var bestA = -1, bestB = -1
            var bestCorr = -Double.infinity
            for a in 0..<memberships.count {
                for b in (a + 1)..<memberships.count {
                    let c = clusterCorrelation(memberships[a], memberships[b], correlation: correlation)
                    if c > bestCorr {
                        bestCorr = c
                        bestA = a
                        bestB = b
                    }
                }
            }
            if bestCorr < threshold || bestA < 0 { break }
            // Merge b into a, drop b.
            memberships[bestA].append(contentsOf: memberships[bestB])
            memberships.remove(at: bestB)
        }

        // Build ObjectiveCluster records.
        let clusters: [ObjectiveCluster] = memberships.map { members in
            let memberNames = members.map { names[$0] }
            let cohesion: Double
            if members.count < 2 {
                cohesion = 1.0
            } else {
                var sum = 0.0
                var cnt = 0
                for i in 0..<members.count {
                    for j in (i + 1)..<members.count {
                        sum += correlation[members[i]][members[j]]
                        cnt += 1
                    }
                }
                cohesion = cnt > 0 ? sum / Double(cnt) : 1.0
            }
            return ObjectiveCluster(
                label: memberNames.joined(separator: "+"),
                members: memberNames,
                cohesion: cohesion
            )
        }.sorted { $0.members[0] < $1.members[0] }

        var idx = [String: Int]()
        for (i, cluster) in clusters.enumerated() {
            for member in cluster.members {
                idx[member] = i
            }
        }
        return ClusterAssignment(clusters: clusters, clusterIndexOf: idx)
    }

    private static func clusterCorrelation(
        _ a: [Int],
        _ b: [Int],
        correlation: [[Double]]
    ) -> Double {
        var sum = 0.0
        var cnt = 0
        for i in a {
            for j in b {
                sum += correlation[i][j]
                cnt += 1
            }
        }
        return cnt > 0 ? sum / Double(cnt) : 0
    }

    private func trivialAssignment(names: [String]) -> ClusterAssignment {
        let clusters = names.enumerated().map { (_, name) in
            ObjectiveCluster(label: name, members: [name], cohesion: 1.0)
        }
        var idx = [String: Int]()
        for (i, c) in clusters.enumerated() { idx[c.members[0]] = i }
        return ClusterAssignment(clusters: clusters, clusterIndexOf: idx)
    }
}
