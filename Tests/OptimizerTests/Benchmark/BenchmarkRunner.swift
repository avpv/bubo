import Foundation
@testable import Bubo

// MARK: - Benchmark Runner
//
// Executes `BuboOptimizer.optimize` for (variant × scenario × seed) cells
// under identical `GAConfiguration` for every cell, so cost-parity is
// structural: same population, same generation cap, same islands. Wallclock
// is measured separately and reported alongside fitness/front metrics so
// the caller can spot "treatment is better but 3× slower" regressions.
//
// Variant plumbing is intentionally thin: `Variant.baseline` is the only
// case today. When FBI/Pareto-PR operators land, each adds a case and a
// preparation closure that installs the operator into the `BuboOptimizer`
// before the call. The harness doesn't need to know *what* the variant
// does — only that two variants must yield the same sized result so metrics
// compare apples to apples.
//
// Scenario output count is set to 20 rather than the production default of
// 3 because Pareto metrics (hypervolume, IGD) need a denser front than
// three diverse picks from MAP-Elites would provide. Scaling to 20 is still
// fast on .quick config.

enum BenchmarkVariant: String, CaseIterable, Sendable {
    case baseline = "baseline"
    // Future: case fbi, case paretoPR, case tabuLNS

    /// Apply variant-specific configuration to a fresh optimizer.
    /// `.baseline` is identity — kept as the honest null case the harness
    /// smoke-tests against itself.
    @MainActor
    func configure(_ optimizer: BuboOptimizer) {
        switch self {
        case .baseline:
            break
        }
    }
}

struct BenchmarkCell: Sendable {
    let scenario: BenchmarkScenario
    let variant: BenchmarkVariant
    let seed: UInt64
}

struct BenchmarkOutcome: Sendable {
    let cell: BenchmarkCell
    /// Best scenario's fitness (the leader among the `scenarioCount` returned).
    let bestFitness: Double
    /// 14-dim objective vectors for every returned scenario, in [0,1] each.
    /// Maximization-sense; higher = better per axis.
    let objectiveVectors: [[Double]]
    /// Names in the order used by `objectiveVectors`. Used by the report to
    /// render per-objective tables.
    let objectiveNames: [String]
    /// Fraction of returned scenarios with zero hard-constraint violations.
    let feasibilityRate: Double
    /// Wallclock for the `optimize()` call alone, excludes fixture build.
    let wallclock: TimeInterval
    /// Generations actually executed before convergence or cap.
    let generations: Int
    /// Per-arm LNS destroy-strategy telemetry after the run. Keyed by
    /// strategy raw value so serialization survives across process runs.
    let lnsArmSnapshot: [String: LNSArmSummary]
}

struct LNSArmSummary: Sendable {
    let weight: Double
    let uses: Int
}

// MARK: - Runner

enum BenchmarkRunner {

    /// Execute a single cell and collect telemetry. All orchestration runs
    /// on the main actor because `BuboOptimizer` is `@MainActor`-bound;
    /// the GA itself still executes on a detached task internally.
    @MainActor
    static func runCell(_ cell: BenchmarkCell) async -> BenchmarkOutcome {
        let optimizer = BuboOptimizer()
        optimizer.gaConfig = .quick
        optimizer.islandConfig = .quick
        // 20 scenarios gives a denser front for Pareto metrics while
        // still fitting comfortably inside .quick (50 pop × 80 gen).
        optimizer.scenarioCount = 20
        cell.variant.configure(optimizer)

        let context = cell.scenario.makeContext(seed: cell.seed)

        let start = Date()
        let result = await optimizer.optimize(context: context)
        let wallclock = Date().timeIntervalSince(start)

        let objectiveNames = canonicalObjectiveNames(from: result.scenarios)
        let vectors = result.scenarios.map { scenario -> [Double] in
            objectiveNames.map { scenario.objectiveBreakdown[$0] ?? 0 }
        }
        let feasibleCount = result.scenarios.filter { $0.constraintViolations.isEmpty }.count
        let feasibilityRate = result.scenarios.isEmpty
            ? 0
            : Double(feasibleCount) / Double(result.scenarios.count)

        // Pull bandit telemetry from the per-workload learners bundle —
        // `optimize` stashes the bundle keyed by TaskSignature, so the
        // same context retrieves the same instance post-run.
        let bundle = optimizer.learners(for: context)
        var arms: [String: LNSArmSummary] = [:]
        for (strategy, telem) in bundle.lnsBandit.snapshot {
            arms[String(describing: strategy)] = LNSArmSummary(
                weight: telem.weight,
                uses: telem.uses
            )
        }

        return BenchmarkOutcome(
            cell: cell,
            bestFitness: result.scenarios.first?.fitness ?? 0,
            objectiveVectors: vectors,
            objectiveNames: objectiveNames,
            feasibilityRate: feasibilityRate,
            wallclock: wallclock,
            generations: result.metadata.generations,
            lnsArmSnapshot: arms
        )
    }

    /// Execute the full (variants × scenarios × seeds) grid sequentially.
    /// Sequential rather than parallel: `BuboOptimizer` is main-actor-bound
    /// and the GA already saturates cores via IslandModelGA, so parallel
    /// cells would fight for the same CPU without shortening wallclock.
    @MainActor
    static func runGrid(
        variants: [BenchmarkVariant],
        scenarios: [BenchmarkScenario],
        seeds: [UInt64]
    ) async -> [BenchmarkOutcome] {
        var out: [BenchmarkOutcome] = []
        out.reserveCapacity(variants.count * scenarios.count * seeds.count)
        for v in variants {
            for s in scenarios {
                for seed in seeds {
                    let cell = BenchmarkCell(scenario: s, variant: v, seed: seed)
                    let outcome = await runCell(cell)
                    out.append(outcome)
                }
            }
        }
        return out
    }

    // MARK: - Pairing

    /// Group outcomes by (scenario, seed) into baseline/treatment pairs.
    /// Any cell without a matching partner is dropped — the paired tests
    /// require equal-sized arrays.
    static func pair(
        outcomes: [BenchmarkOutcome],
        baseline: BenchmarkVariant,
        treatment: BenchmarkVariant
    ) -> [(baseline: BenchmarkOutcome, treatment: BenchmarkOutcome)] {
        var base: [String: BenchmarkOutcome] = [:]
        var treat: [String: BenchmarkOutcome] = [:]
        for o in outcomes {
            let key = "\(o.cell.scenario.rawValue)|\(o.cell.seed)"
            if o.cell.variant == baseline { base[key] = o }
            if o.cell.variant == treatment { treat[key] = o }
        }
        var pairs: [(BenchmarkOutcome, BenchmarkOutcome)] = []
        for (key, b) in base {
            if let t = treat[key] { pairs.append((b, t)) }
        }
        // Deterministic order for reproducible reports.
        return pairs.sorted {
            "\($0.0.cell.scenario.rawValue)|\($0.0.cell.seed)"
                < "\($1.0.cell.scenario.rawValue)|\($1.0.cell.seed)"
        }
    }

    // MARK: - Helpers

    /// Stable objective ordering for vector construction. We take the keys
    /// of the first scenario's breakdown (the evaluator writes them in a
    /// fixed order) and sort alphabetically — the specific order doesn't
    /// affect metric values (hypervolume/IGD are symmetric in axis names)
    /// but *consistency* across outcomes does.
    private static func canonicalObjectiveNames(from scenarios: [ScheduleScenario]) -> [String] {
        var union: Set<String> = []
        for s in scenarios { union.formUnion(s.objectiveBreakdown.keys) }
        return union.sorted()
    }
}
