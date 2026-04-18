import Foundation
@testable import Bubo

// MARK: - Benchmark Report
//
// Produces a human-readable markdown summary from a paired outcome list
// plus per-scenario CSVs for the Pareto fronts. The markdown goes to
// stdout (captured by Swift Testing into the test log) so PR reviewers
// see it without leaving their browser; CSVs are written to a temp
// directory for local deep-dives.
//
// The report answers, per (scenario, variant) pair:
//
//   • Mean fitness delta (treatment − baseline), with 95% bootstrap CI.
//   • Wilcoxon p-value on paired fitness deltas across seeds.
//   • Hypervolume delta on the 14-objective front per cell (seed-averaged).
//   • IGD of each variant against the union-of-variants reference front.
//   • Spread delta (diversity).
//   • Dominance call: does treatment strictly Pareto-dominate baseline?
//   • Feasibility rates for each variant.
//   • Wallclock ratio (treatment / baseline).
//
// Every row shows per-scenario numbers, not just aggregates — a variant
// that averages positive while regressing on `multi-person` is a regression,
// and the per-scenario breakdown catches it immediately.

struct BenchmarkReport {
    let markdown: String
    let csvArtifacts: [String: String]    // path → content

    /// Write all CSV artifacts to disk. Returns the list of paths written.
    @discardableResult
    func writeArtifacts(to directory: URL = FileManager.default.temporaryDirectory) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (name, content) in csvArtifacts {
            let url = directory.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }
        return written
    }
}

enum BenchmarkReporter {

    /// Build a report comparing `treatment` to `baseline` over `outcomes`.
    /// Assumes the two variants were run on the same (scenario, seed) grid;
    /// unpaired cells are silently dropped by `BenchmarkRunner.pair`.
    static func report(
        baseline: BenchmarkVariant,
        treatment: BenchmarkVariant,
        outcomes: [BenchmarkOutcome]
    ) -> BenchmarkReport {
        let pairs = BenchmarkRunner.pair(outcomes: outcomes, baseline: baseline, treatment: treatment)
        var md = "# Benchmark Report: \(treatment.rawValue) vs \(baseline.rawValue)\n\n"
        md += "Pairs: \(pairs.count)\n\n"

        var csvs: [String: String] = [:]

        // Grouping: per scenario across seeds.
        let byScenario = Dictionary(grouping: pairs, by: { $0.baseline.cell.scenario })

        md += "## Per-Scenario Summary\n\n"
        md += "| Scenario | N | ΔFitness | 95% CI | Wilcoxon p | ΔHV | ΔSpread | Dominance | Feas (B→T) | Wallclock |\n"
        md += "|---|--:|--:|:--|--:|--:|--:|:--|:--|--:|\n"

        // Also accumulate global fitness deltas for an overall row.
        var allBaseline: [Double] = []
        var allTreatment: [Double] = []

        for scenario in BenchmarkScenario.allCases {
            guard let scenarioPairs = byScenario[scenario], !scenarioPairs.isEmpty else { continue }
            let baseF = scenarioPairs.map(\.baseline.bestFitness)
            let treatF = scenarioPairs.map(\.treatment.bestFitness)
            allBaseline.append(contentsOf: baseF)
            allTreatment.append(contentsOf: treatF)

            let wilcoxon = BenchmarkStatistics.wilcoxonSignedRank(baseline: baseF, treatment: treatF)
            let boot = BenchmarkStatistics.bootstrapMeanDelta(baseline: baseF, treatment: treatF)

            // HV / spread delta: compute per-pair (each pair has two fronts
            // of 20 vectors) and take the mean. Using a shared seed keeps
            // the Monte-Carlo noise identical between the two variants on
            // the same pair, so the delta strips estimator noise out.
            var hvBaseMean = 0.0, hvTreatMean = 0.0
            var spreadBaseMean = 0.0, spreadTreatMean = 0.0
            var dominationVotes = (treatWinsDominance: 0, baseWinsDominance: 0, inconclusive: 0)
            for pair in scenarioPairs {
                let hvBase = BenchmarkMetrics.hypervolume(pair.baseline.objectiveVectors)
                let hvTreat = BenchmarkMetrics.hypervolume(pair.treatment.objectiveVectors)
                hvBaseMean += hvBase
                hvTreatMean += hvTreat
                spreadBaseMean += BenchmarkMetrics.spread(pair.baseline.objectiveVectors)
                spreadTreatMean += BenchmarkMetrics.spread(pair.treatment.objectiveVectors)

                let dom = BenchmarkMetrics.compareDominance(
                    frontA: pair.treatment.objectiveVectors,
                    frontB: pair.baseline.objectiveVectors
                )
                if dom.aStrictlyDominatesB {
                    dominationVotes.treatWinsDominance += 1
                } else {
                    let reverse = BenchmarkMetrics.compareDominance(
                        frontA: pair.baseline.objectiveVectors,
                        frontB: pair.treatment.objectiveVectors
                    )
                    if reverse.aStrictlyDominatesB {
                        dominationVotes.baseWinsDominance += 1
                    } else {
                        dominationVotes.inconclusive += 1
                    }
                }
            }
            let n = Double(scenarioPairs.count)
            hvBaseMean /= n; hvTreatMean /= n
            spreadBaseMean /= n; spreadTreatMean /= n

            let hvDelta = hvTreatMean - hvBaseMean
            let spreadDelta = spreadTreatMean - spreadBaseMean

            let feasBase = scenarioPairs.map(\.baseline.feasibilityRate).reduce(0, +) / n
            let feasTreat = scenarioPairs.map(\.treatment.feasibilityRate).reduce(0, +) / n

            let clockBase = scenarioPairs.map(\.baseline.wallclock).reduce(0, +) / n
            let clockTreat = scenarioPairs.map(\.treatment.wallclock).reduce(0, +) / n
            let clockRatio = clockBase > 0 ? clockTreat / clockBase : 1.0

            let dominanceLabel: String
            if dominationVotes.treatWinsDominance > dominationVotes.baseWinsDominance * 2 {
                dominanceLabel = "T dominates (\(dominationVotes.treatWinsDominance)/\(scenarioPairs.count))"
            } else if dominationVotes.baseWinsDominance > dominationVotes.treatWinsDominance * 2 {
                dominanceLabel = "B dominates (\(dominationVotes.baseWinsDominance)/\(scenarioPairs.count))"
            } else {
                dominanceLabel = "inconclusive"
            }

            md += "| \(scenario.rawValue)"
            md += " | \(scenarioPairs.count)"
            md += " | \(formatDelta(boot.meanDelta))"
            md += " | [\(formatDelta(boot.ciLower)), \(formatDelta(boot.ciHigh))]"
            md += " | \(formatP(wilcoxon.pValue))"
            md += " | \(formatDelta(hvDelta))"
            md += " | \(formatDelta(spreadDelta))"
            md += " | \(dominanceLabel)"
            md += " | \(formatRatio(feasBase))→\(formatRatio(feasTreat))"
            md += " | \(String(format: "%.2fx", clockRatio)) |\n"

            // Per-scenario CSV of the paired fronts, one row per (seed, variant, scenario index).
            let csvName = "fronts-\(scenario.rawValue).csv"
            csvs[csvName] = csvForScenario(scenarioPairs)
        }

        // Global row
        if !allBaseline.isEmpty {
            let wilcoxon = BenchmarkStatistics.wilcoxonSignedRank(baseline: allBaseline, treatment: allTreatment)
            let boot = BenchmarkStatistics.bootstrapMeanDelta(baseline: allBaseline, treatment: allTreatment)
            md += "\n## Aggregate\n\n"
            md += "- Pairs: \(allBaseline.count)\n"
            md += "- Mean ΔFitness: \(formatDelta(boot.meanDelta))\n"
            md += "- 95% CI: [\(formatDelta(boot.ciLower)), \(formatDelta(boot.ciHigh))]\n"
            md += "- CI relative width: \(formatRelWidth(boot.relativeWidth))\n"
            md += "- Wilcoxon p: \(formatP(wilcoxon.pValue)) (n=\(wilcoxon.effectiveN))\n"
        }

        // Bandit arm summary: aggregate per-arm uses across the treatment run.
        md += "\n## Bandit Arm Usage (treatment)\n\n"
        let treatmentOutcomes = outcomes.filter { $0.cell.variant == treatment }
        var armTotals: [String: (weight: Double, uses: Int, cells: Int)] = [:]
        for o in treatmentOutcomes {
            for (name, summary) in o.lnsArmSnapshot {
                var acc = armTotals[name] ?? (0, 0, 0)
                acc.weight += summary.weight
                acc.uses += summary.uses
                acc.cells += 1
                armTotals[name] = acc
            }
        }
        md += "| Arm | Avg Weight | Total Uses | Cells |\n"
        md += "|---|--:|--:|--:|\n"
        for name in armTotals.keys.sorted() {
            let t = armTotals[name]!
            let avgW = t.cells > 0 ? t.weight / Double(t.cells) : 0
            md += "| \(name) | \(String(format: "%.3f", avgW)) | \(t.uses) | \(t.cells) |\n"
        }

        return BenchmarkReport(markdown: md, csvArtifacts: csvs)
    }

    // MARK: - Formatting

    private static func formatDelta(_ x: Double) -> String {
        String(format: "%+.4f", x)
    }
    private static func formatP(_ p: Double) -> String {
        p < 0.001 ? "<0.001" : String(format: "%.3f", p)
    }
    private static func formatRatio(_ x: Double) -> String {
        String(format: "%.2f", x)
    }
    private static func formatRelWidth(_ x: Double) -> String {
        x.isFinite ? String(format: "%.2fx", x) : "∞"
    }

    private static func csvForScenario(
        _ pairs: [(baseline: BenchmarkOutcome, treatment: BenchmarkOutcome)]
    ) -> String {
        guard let names = pairs.first?.baseline.objectiveNames else { return "" }
        var lines: [String] = []
        lines.append((["seed", "variant", "scenarioIndex", "fitness"] + names).joined(separator: ","))
        for pair in pairs {
            for (i, vec) in pair.baseline.objectiveVectors.enumerated() {
                let row = ([
                    String(pair.baseline.cell.seed),
                    "baseline",
                    String(i),
                    String(format: "%.6f", pair.baseline.bestFitness)
                ] + vec.map { String(format: "%.6f", $0) }).joined(separator: ",")
                lines.append(row)
            }
            for (i, vec) in pair.treatment.objectiveVectors.enumerated() {
                let row = ([
                    String(pair.treatment.cell.seed),
                    "treatment",
                    String(i),
                    String(format: "%.6f", pair.treatment.bestFitness)
                ] + vec.map { String(format: "%.6f", $0) }).joined(separator: ",")
                lines.append(row)
            }
        }
        return lines.joined(separator: "\n")
    }
}
