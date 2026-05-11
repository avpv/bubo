import Foundation

// MARK: - GA Configuration

struct GAConfiguration: Sendable {
    var populationSize: Int
    var maxGenerations: Int
    var mutationRate: Double
    var crossoverRate: Double
    var eliteCount: Int
    var selectionStrategy: SelectionStrategy
    var crossoverStrategy: CrossoverStrategy
    var convergenceThreshold: Double   // stop if fitness improvement < this for N generations
    var convergencePatience: Int       // number of stale generations before stopping
    var adaptiveMutation: Bool
    var diversityThreshold: Double     // below this diversity, boost mutation & inject immigrants
    var immigrationRate: Double        // fraction of population replaced by random immigrants on stagnation

    /// Fraction of initial population seeded with greedy heuristic (0 = all random, 0.2 = 20% greedy).
    /// Greedy seeds give the GA feasible starting points, especially useful for fast configs.
    var greedySeedFraction: Double

    /// Enable repair operator after crossover/mutation to fix constraint violations.
    /// Converts infeasible offspring into feasible ones, avoiding wasted evaluations.
    var enableRepair: Bool

    /// Enable adaptive crossover rate (decays with generation progress).
    var adaptiveCrossover: Bool

    /// Run a short SA hill climb on the top individuals every N generations
    /// during evolution, not just once at the end. 0 disables (pure GA).
    /// Memetic intermediate hill climbing typically delivers +5-10% final
    /// fitness for ~2-5% extra cost, because the climbs happen to the top
    /// individuals whose refinements then propagate through selection.
    var memeticHillClimbInterval: Int

    /// Number of individuals to hill-climb on each memetic pass.
    var memeticHillClimbCandidates: Int

    /// Steps per memetic hill climb invocation. Keep modest — the point is
    /// frequent local refinement, not a full deep optimization every cycle.
    var memeticHillClimbSteps: Int

    /// CHC-style restart: when the stagnation patience is exhausted,
    /// instead of giving up, keep the top-K individuals and regenerate the
    /// rest with high-rate mutation. 0 disables and the old "stop on
    /// stagnation" behaviour is preserved. Values > 0 grant the evolution
    /// this many restarts before actually stopping; each restart resets the
    /// stagnation counter and lets the GA attack the landscape from a fresh
    /// direction, which is often enough to escape basins immigration can't.
    var chcMaxRestarts: Int

    /// Fraction of the population kept verbatim at each CHC restart. The
    /// rest are regenerated from those elites via high-rate mutation (0.35
    /// per gene is standard CHC). Typically 0.1-0.2 — large enough to
    /// preserve discovered structure, small enough to leave room for
    /// meaningful renewal.
    var chcRestartEliteFraction: Double

    /// Per-gene mutation rate used when regenerating the non-elite portion
    /// on a CHC restart. CHC's defining trick is this being much higher
    /// than the normal rate so the regenerated portion really does probe a
    /// different neighbourhood.
    var chcRestartMutationRate: Double

    /// When true, initial individuals get `selfAdaptiveMutationRate =
    /// mutationRate`, and every mutation perturbs that value. Chromosomes
    /// whose rates produced better fitness propagate their rates through
    /// crossover, so the population's effective mutation rate drifts
    /// toward whatever is working for the current landscape — no manual
    /// tuning of `mutationRate` per workload.
    var selfAdaptiveRates: Bool

    /// Wallclock ceiling on the evolution loop. When > 0, both
    /// `GeneticAlgorithm.evolve` and `IslandModelGA.evolveIslands`
    /// exit between generations once this many seconds have elapsed
    /// since the loop started, regardless of `maxGenerations` or
    /// `convergencePatience`. Value 0 disables the timeout (legacy
    /// behaviour). Callers driving interactive UIs set this to keep
    /// "plan week" responsive on small backlogs where GA would
    /// otherwise burn its full generation budget on a trivially-
    /// schedulable workload.
    var wallclockTimeout: TimeInterval

    // Schedule-specific tunables (QD emission rate, gradient
    // refinement interval) used to live here. They've moved into the
    // hook closures that the host wires via `EvolutionHooks`, so
    // the engine no longer needs to know about them. Keep this file
    // strictly about the generic GA cycle.

    init(
        populationSize: Int,
        maxGenerations: Int,
        mutationRate: Double,
        crossoverRate: Double,
        eliteCount: Int,
        selectionStrategy: SelectionStrategy,
        crossoverStrategy: CrossoverStrategy,
        convergenceThreshold: Double,
        convergencePatience: Int,
        adaptiveMutation: Bool,
        diversityThreshold: Double,
        immigrationRate: Double,
        greedySeedFraction: Double = 0.0,
        enableRepair: Bool = false,
        adaptiveCrossover: Bool = false,
        memeticHillClimbInterval: Int = 0,
        memeticHillClimbCandidates: Int = 3,
        memeticHillClimbSteps: Int = 5,
        chcMaxRestarts: Int = 0,
        chcRestartEliteFraction: Double = 0.15,
        chcRestartMutationRate: Double = 0.35,
        selfAdaptiveRates: Bool = false,
        wallclockTimeout: TimeInterval = 0
    ) {
        self.populationSize = populationSize
        self.maxGenerations = maxGenerations
        self.mutationRate = mutationRate
        self.crossoverRate = crossoverRate
        self.eliteCount = eliteCount
        self.selectionStrategy = selectionStrategy
        self.crossoverStrategy = crossoverStrategy
        self.convergenceThreshold = convergenceThreshold
        self.convergencePatience = convergencePatience
        self.adaptiveMutation = adaptiveMutation
        self.diversityThreshold = diversityThreshold
        self.immigrationRate = immigrationRate
        self.greedySeedFraction = greedySeedFraction
        self.enableRepair = enableRepair
        self.adaptiveCrossover = adaptiveCrossover
        self.memeticHillClimbInterval = memeticHillClimbInterval
        self.memeticHillClimbCandidates = memeticHillClimbCandidates
        self.memeticHillClimbSteps = memeticHillClimbSteps
        self.chcMaxRestarts = chcMaxRestarts
        self.chcRestartEliteFraction = chcRestartEliteFraction
        self.chcRestartMutationRate = chcRestartMutationRate
        self.selfAdaptiveRates = selfAdaptiveRates
        self.wallclockTimeout = wallclockTimeout
    }

    static let `default` = GAConfiguration(
        populationSize: 100,
        maxGenerations: 200,
        mutationRate: 0.15,
        crossoverRate: 0.8,
        eliteCount: 3,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .contextual(temperature: 0.5),
        convergenceThreshold: 0.001,
        // Lower patience (was 30). With the stronger greedy seeding
        // below, the initial population usually already contains the
        // fitness-plateau winner; waiting 30 generations to confirm
        // that nothing beats it burned most of the wallclock budget
        // on workloads that converge immediately.
        convergencePatience: 15,
        adaptiveMutation: true,
        diversityThreshold: 0.01,
        immigrationRate: 0.1,
        // Greedy share bumped from 0.15 to 0.35 — seeds the population
        // with feasible (priority, backlog, deadline)-ordered layouts
        // so the GA starts polishing a near-optimal solution instead
        // of discovering the sort key from random shuffles.
        greedySeedFraction: 0.35,
        enableRepair: true,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 25,
        memeticHillClimbCandidates: 3,
        memeticHillClimbSteps: 6,
        chcMaxRestarts: 1,
        chcRestartEliteFraction: 0.15,
        chcRestartMutationRate: 0.35,
        selfAdaptiveRates: true,
        wallclockTimeout: 8.0
    )

    static let quick = GAConfiguration(
        populationSize: 50,
        maxGenerations: 80,
        mutationRate: 0.2,
        crossoverRate: 0.8,
        eliteCount: 2,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .contextual(temperature: 0.7),
        convergenceThreshold: 0.005,
        convergencePatience: 8,
        adaptiveMutation: false,
        diversityThreshold: 0.01,
        immigrationRate: 0.1,
        greedySeedFraction: 0.4,
        enableRepair: true,
        adaptiveCrossover: false,
        wallclockTimeout: 3.0
    )

    /// Ultra-fast config for live preview and drag-to-schedule reflow.
    /// ~20 generations, ~100ms on modern hardware.
    /// Trades optimality for speed — good enough for preview, not final schedule.
    /// Uses single-point crossover to skip attention-scoring overhead.
    static let instant = GAConfiguration(
        populationSize: 20,
        maxGenerations: 20,
        mutationRate: 0.25,
        crossoverRate: 0.7,
        eliteCount: 1,
        selectionStrategy: .tournament(size: 2),
        crossoverStrategy: .singlePoint,
        convergenceThreshold: 0.01,
        convergencePatience: 5,
        adaptiveMutation: false,
        diversityThreshold: 0.05,
        immigrationRate: 0.0,
        greedySeedFraction: 0.5,
        enableRepair: true,
        adaptiveCrossover: false,
        wallclockTimeout: 0.5
    )

    /// Polish configuration — GA runs *after* CP-SAT has found the
    /// hard+mid tier optimum and the job is just to refine soft-tier
    /// placement (Buffer, ContextSwitch, DayCompactness, EnergyCurve)
    /// in the neighbourhood of the anchor.
    ///
    /// Shape is deliberately lean:
    ///   • Tiny population because the anchor is already great —
    ///     we're not searching, we're sampling a small basin.
    ///   • Low mutation rate so perturbations stay local to the
    ///     CP-SAT anchor and don't re-discover hard+mid violations
    ///     that the anchor already solved.
    ///   • No CHC restart: restart would throw away the anchor's
    ///     structural win and is only useful when the GA is stuck,
    ///     which it can't be on a trivially-polishable landscape.
    ///   • Short wallclock + tight patience so the whole polish
    ///     phase costs ~100-500ms even on the thorough path.
    ///
    /// `IslandModelGA` adds anchor-replication seeds on top: a
    /// large fraction of the initial population is CP-SAT mutated
    /// with ±1–2 slot jitter, so the GA's first generation is a
    /// dense cloud around the lex-optimum. Remaining slots are
    /// filled with greedy variants and random for diversity.
    static let polish = GAConfiguration(
        populationSize: 30,
        maxGenerations: 25,
        mutationRate: 0.08,
        crossoverRate: 0.75,
        eliteCount: 2,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .contextual(temperature: 0.4),
        convergenceThreshold: 0.002,
        convergencePatience: 6,
        adaptiveMutation: true,
        diversityThreshold: 0.02,
        immigrationRate: 0.05,
        greedySeedFraction: 0.2,
        enableRepair: true,
        adaptiveCrossover: false,
        memeticHillClimbInterval: 10,
        memeticHillClimbCandidates: 2,
        memeticHillClimbSteps: 4,
        chcMaxRestarts: 0,
        chcRestartEliteFraction: 0.0,
        chcRestartMutationRate: 0.0,
        selfAdaptiveRates: true,
        wallclockTimeout: 1.5
    )

    /// Refine configuration — GA after CP-SAT on a medium workload
    /// where the anchor is feasible-optimal but soft tier has real
    /// search space (20-40 events, some conflicts). Between
    /// `polish` and `default` in every axis.
    static let refine = GAConfiguration(
        populationSize: 60,
        maxGenerations: 80,
        mutationRate: 0.12,
        crossoverRate: 0.8,
        eliteCount: 3,
        selectionStrategy: .tournament(size: 3),
        crossoverStrategy: .contextual(temperature: 0.5),
        convergenceThreshold: 0.001,
        convergencePatience: 12,
        adaptiveMutation: true,
        diversityThreshold: 0.015,
        immigrationRate: 0.08,
        greedySeedFraction: 0.25,
        enableRepair: true,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 20,
        memeticHillClimbCandidates: 3,
        memeticHillClimbSteps: 5,
        chcMaxRestarts: 1,
        chcRestartEliteFraction: 0.2,
        chcRestartMutationRate: 0.3,
        selfAdaptiveRates: true,
        wallclockTimeout: 4.0
    )

    static let thorough = GAConfiguration(
        populationSize: 200,
        maxGenerations: 500,
        mutationRate: 0.1,
        crossoverRate: 0.85,
        eliteCount: 5,
        selectionStrategy: .tournament(size: 5),
        crossoverStrategy: .contextual(temperature: 0.5),
        convergenceThreshold: 0.0005,
        // Patience trimmed 50 → 25: on tiny workloads `.thorough`
        // used to run until the wallclock killed it because the
        // greedy seed hit the plateau in gen 0-2 and then sat there
        // unchanged for 50 generations of "no improvement" waiting.
        // 25 plus `migrationInterval` still gives deep exploration
        // room on hard problems while letting trivial ones exit.
        convergencePatience: 25,
        adaptiveMutation: true,
        diversityThreshold: 0.005,
        immigrationRate: 0.15,
        greedySeedFraction: 0.35,
        enableRepair: true,
        adaptiveCrossover: true,
        memeticHillClimbInterval: 40,
        memeticHillClimbCandidates: 5,
        memeticHillClimbSteps: 10,
        chcMaxRestarts: 2,
        chcRestartEliteFraction: 0.15,
        chcRestartMutationRate: 0.35,
        selfAdaptiveRates: true,
        wallclockTimeout: 20.0
    )

}
