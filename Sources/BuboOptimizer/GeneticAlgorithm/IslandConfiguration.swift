import Foundation

// MARK: - Island Model Configuration

/// Configuration for the Island Model genetic algorithm.
/// Multiple populations (islands) evolve in parallel with periodic migration
/// of individuals between islands, enabling better exploration of the solution space.
public struct IslandConfiguration: Sendable {

    public init(
        islandCount: Int,
        migrationInterval: Int,
        migrationSize: Int,
        topology: MigrationTopology,
        emigrantSelection: EmigrantSelection,
        immigrantReplacement: ImmigrantReplacement,
        diversifyIslands: Bool,
        adaptiveMigration: Bool,
        routeByProductivity: Bool = false,
        objectiveWeightBiases: [Int: [String: Double]]? = nil
    ) {
        self.islandCount = islandCount
        self.migrationInterval = migrationInterval
        self.migrationSize = migrationSize
        self.topology = topology
        self.emigrantSelection = emigrantSelection
        self.immigrantReplacement = immigrantReplacement
        self.diversifyIslands = diversifyIslands
        self.adaptiveMigration = adaptiveMigration
        self.routeByProductivity = routeByProductivity
        self.objectiveWeightBiases = objectiveWeightBiases
    }

    /// Number of parallel island populations.
    public var islandCount: Int

    /// Number of generations between migration events.
    public var migrationInterval: Int

    /// Number of individuals migrated per island per event.
    public var migrationSize: Int

    /// How islands are connected for migration.
    public var topology: MigrationTopology

    /// Strategy for selecting emigrants from a source island.
    public var emigrantSelection: EmigrantSelection

    /// Strategy for replacing individuals on the receiving island.
    public var immigrantReplacement: ImmigrantReplacement

    /// Whether to diversify GA parameters across islands for heterogeneous search.
    /// When true, islands get varied mutation rates, selection strategies, and crossover
    /// strategies to explore different regions of the search space.
    public var diversifyIslands: Bool

    /// Whether to adapt migration frequency/size based on global stagnation and
    /// cross-island diversity. When true, migration intensifies when progress stalls
    /// and relaxes when islands are still diverging productively.
    public var adaptiveMigration: Bool

    /// When true, each migration pair's direction is flipped so the
    /// more-productive endpoint is the source and the less-productive
    /// endpoint is the destination. Topology still determines *which*
    /// islands exchange; this flag only controls *who sends to whom*.
    /// Productivity is measured as `bestEver.rawFitness`.
    public var routeByProductivity: Bool = false

    /// Optional per-island objective-weight multipliers. Keyed by
    /// island index (0-based); inner dictionary keyed by objective
    /// name (the `FitnessObjective.name` string, e.g. `"Conflict"`,
    /// `"WeekBalance"`). Each multiplier is applied to the baseline
    /// preference weight for that objective on that island.
    ///
    /// Classical island-model GA assumes every island shares the
    /// exact same fitness landscape; in practice different islands
    /// converging on different regions of the Pareto surface is
    /// usually a *feature*, not a bug, and biasing each island's
    /// objective weights pushes the convergence away from monoculture
    /// without giving up the scalar-fitness survivor selection.
    ///
    /// Example: `[0: ["Conflict": 1.5], 1: ["WeekBalance": 2.0]]`
    /// gives island 0 a conflict-hawk personality (prefers
    /// conflict-free schedules even at the cost of balance) and
    /// island 1 a balance-first personality. Migration still works
    /// unchanged — incoming migrants re-evaluate against the
    /// receiving island's preferences so fitness is consistent
    /// within each island.
    ///
    /// `nil` (default) = every island uses the unbiased preferences.
    public var objectiveWeightBiases: [Int: [String: Double]]? = nil

    /// Fast configs: 2 islands, frequent migration, no diversification.
    /// Adds modest exploration benefit without significant overhead.
    public static let quick = IslandConfiguration(
        islandCount: 2,
        migrationInterval: 10,
        migrationSize: 2,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: false,
        adaptiveMigration: false,
        routeByProductivity: false
    )

    public static let `default` = IslandConfiguration(
        islandCount: 4,
        migrationInterval: 20,
        migrationSize: 3,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: true,
        adaptiveMigration: true,
        routeByProductivity: true
    )

    /// Larger island count for deep weekly planning.
    public static let thorough = IslandConfiguration(
        islandCount: 6,
        migrationInterval: 25,
        migrationSize: 4,
        topology: .ring,
        emigrantSelection: .best,
        immigrantReplacement: .worst,
        diversifyIslands: true,
        adaptiveMigration: true,
        routeByProductivity: true
    )

    /// Validate configuration, clamping values to safe ranges.
    /// Call this before passing to `IslandModelGA`.
    public func validated(populationSize: Int) -> IslandConfiguration {
        var copy = self
        copy.islandCount = max(1, islandCount)
        copy.migrationInterval = max(1, migrationInterval)
        copy.migrationSize = max(1, min(migrationSize, populationSize / 2))
        return copy
    }
}

// MARK: - Migration Topology

/// Defines the connectivity pattern between islands for migration.
public enum MigrationTopology: Sendable {
    /// Unidirectional ring: island i sends to island (i+1) % n.
    /// Low connectivity preserves island diversity longer.
    case ring

    /// Every island sends migrants to every other island.
    /// High connectivity accelerates convergence but reduces diversity.
    case fullyConnected

    /// Random pairs of islands exchange individuals each migration event.
    /// Moderate connectivity with stochastic variety.
    case randomPairs
}

// MARK: - Emigrant Selection

/// How individuals are chosen to migrate from a source island.
public enum EmigrantSelection: Sendable {
    /// Select the best individuals from the source island.
    case best

    /// Tournament selection from the source island.
    case tournament(size: Int)
}

// MARK: - Immigrant Replacement

/// How incoming migrants replace individuals on the receiving island.
public enum ImmigrantReplacement: Sendable, Equatable {
    /// Replace the worst individuals on the receiving island.
    case worst

    /// Replace random individuals (excluding elites) on the receiving island.
    case random
}

// MARK: - Cross-Island Diversity

/// Measures how different the best solutions across islands are.
/// Used by adaptive migration to decide when to intensify or relax migration.
public struct CrossIslandDiversity {

    public init(
        uniqueBestFraction: Double,
        fitnessRange: Double,
        fitnessStdDev: Double
    ) {
        self.uniqueBestFraction = uniqueBestFraction
        self.fitnessRange = fitnessRange
        self.fitnessStdDev = fitnessStdDev
    }

    /// Fraction of island best individuals that are genetically unique (by Equatable).
    /// 0 = all islands converged to same solution, 1 = all islands have different bests.
    public let uniqueBestFraction: Double

    /// Range of best fitness values across islands (max - min).
    /// 0 = all islands found equal-quality solutions.
    public let fitnessRange: Double

    /// Standard deviation of best fitness values across islands.
    public let fitnessStdDev: Double
}

// MARK: - Island Progress

/// Progress information aggregated across all islands.
public struct IslandModelProgress: Sendable {

    public init(
        generation: Int,
        globalBestFitness: Double,
        islandBestFitnesses: [Double],
        islandDiversities: [Double],
        migrationsPerformed: Int,
        crossIslandDiversity: Double,
        effectiveMigrationInterval: Int
    ) {
        self.generation = generation
        self.globalBestFitness = globalBestFitness
        self.islandBestFitnesses = islandBestFitnesses
        self.islandDiversities = islandDiversities
        self.migrationsPerformed = migrationsPerformed
        self.crossIslandDiversity = crossIslandDiversity
        self.effectiveMigrationInterval = effectiveMigrationInterval
    }

    public let generation: Int
    public let globalBestFitness: Double
    public let islandBestFitnesses: [Double]
    public let islandDiversities: [Double]
    public let migrationsPerformed: Int
    /// Cross-island diversity: how different island bests are from each other.
    public let crossIslandDiversity: Double
    /// Current effective migration interval (may differ from config when adaptive).
    public let effectiveMigrationInterval: Int
}
