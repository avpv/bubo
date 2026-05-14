import Foundation

// MARK: - Per-island GA configuration generator
//
// Builds the array of `GAConfiguration` values consumed by each island
// in the island-model run. When `diversifyIslands` is enabled, the
// configurations are *intentionally* heterogeneous — mutation rate,
// crossover rate, and selection strategy vary across islands so the
// populations explore different regions of the search landscape — and
// `routeByProductivity` later steers offspring toward the islands
// pulling their weight.
//
// Extracted from `IslandModelGA.swift` to keep the configuration-shape
// recipe near the islands' configuration types in `IslandConfiguration.swift`
// rather than buried after ~900 lines of evolution / migration code.

public extension IslandModelGA {

    // MARK: - Island Configuration Diversification

    /// Create per-island GA configurations. When diversification is enabled,
    /// islands get varied parameters to explore different regions of the
    /// search space. Crowding/sharing knobs were dropped with the NSGA-III
    /// rewrite; diversity is now a first-class property of survivor
    /// selection, so per-island variation focuses on exploration versus
    /// exploitation via mutation rate, selection strategy, and crossover
    /// operator.
    func makeIslandConfigs() -> [GAConfiguration] {
        guard islandConfig.diversifyIslands else {
            return Array(repeating: baseConfig, count: islandConfig.islandCount)
        }

        var configs: [GAConfiguration] = []

        for i in 0..<islandConfig.islandCount {
            var config = baseConfig
            switch i {
            case 0:
                // Island 0: exploitation — base config, heavy greedy
                // seeding so the "starts right" half of the population
                // is concentrated here. Island 1 (exploration) stays
                // at zero greedy share to preserve the diversity
                // dimension that made the multi-island setup worth
                // paying for in the first place.
                config.greedySeedFraction = 0.5
                config.enableRepair = true

            case 1:
                // Island 1: exploration — higher mutation, smaller
                // tournaments to reduce selection pressure so rare
                // mutations survive long enough to get evaluated.
                config.mutationRate = min(0.4, baseConfig.mutationRate * 2.5)
                config.selectionStrategy = .tournament(size: 2)
                config.adaptiveMutation = false
                config.greedySeedFraction = 0.0

            case 2:
                // Island 2: niching via rank selection. NSGA-III gives us
                // niche preservation on the survivor side; rank selection
                // on the parent side flattens fitness pressure so weaker
                // individuals still contribute genes to offspring.
                config.selectionStrategy = .rank
                config.mutationRate = baseConfig.mutationRate * 1.3
                config.greedySeedFraction = 0.3

            case 3:
                // Island 3: day-block crossover — preserves bundled day
                // structures ("morning meeting block") instead of splitting
                // gene-by-gene. Pairs well with adaptive crossover so early
                // generations mix days aggressively and late ones settle.
                config.crossoverStrategy = .dayBlock
                config.crossoverRate = 0.9
                config.adaptiveCrossover = true
                config.greedySeedFraction = 0.3

            default:
                // Additional islands: deterministic parameter variations
                // based on index. Each island gets a unique combination so
                // results are reproducible.
                let variations: [(mutMul: Double, xRate: Double, sel: SelectionStrategy)] = [
                    (1.8, 0.75, .tournament(size: 3)),
                    (0.7, 0.90, .stochasticUniversalSampling),
                    (2.2, 0.80, .tournament(size: 5)),
                    (1.5, 0.70, .rank),
                ]
                let v = variations[(i - 4) % variations.count]
                config.mutationRate = baseConfig.mutationRate * v.mutMul
                config.crossoverRate = v.xRate
                config.selectionStrategy = v.sel
            }
            configs.append(config)
        }

        return configs
    }
}
