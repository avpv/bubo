import Foundation

// MARK: - Pomodoro Sequence Chromosome

/// A chromosome that encodes a permutation of tasks within a Pomodoro session.
/// While ScheduleChromosome decides *when* to schedule events,
/// PomodoroSequenceChromosome decides *in what order* to do tasks
/// within an already-allocated time block.
///
/// Genes = indices into the task list (a permutation).
/// Fitness considers energy curve, context switches, deadlines, and cognitive load.
struct PomodoroSequenceChromosome: Chromosome, Sendable {
    /// Each element is an index into the task list — the array is a permutation.
    var sequence: [Int]
    var fitness: Double = 0.0
    var needsEvaluation: Bool = true

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence && lhs.fitness == rhs.fitness
    }

    // MARK: - Random Initialization

    static func random(context: OptimizerContext) -> PomodoroSequenceChromosome {
        let count = context.movableEvents.count
        var sequence = Array(0..<count)
        sequence.shuffle()
        return PomodoroSequenceChromosome(sequence: sequence, needsEvaluation: true)
    }

    // MARK: - Order Crossover (OX1)

    /// Order crossover preserves relative ordering from both parents
    /// while producing valid permutations.
    func crossover(
        with other: PomodoroSequenceChromosome,
        context: OptimizerContext
    ) -> (PomodoroSequenceChromosome, PomodoroSequenceChromosome) {
        let n = sequence.count
        guard n > 2 else { return (self, other) }

        let child1 = orderCrossover(parent1: sequence, parent2: other.sequence)
        let child2 = orderCrossover(parent1: other.sequence, parent2: sequence)

        return (
            PomodoroSequenceChromosome(sequence: child1, needsEvaluation: true),
            PomodoroSequenceChromosome(sequence: child2, needsEvaluation: true)
        )
    }

    /// OX1: copy a random segment from parent1, fill the rest from parent2 in order.
    private func orderCrossover(parent1: [Int], parent2: [Int]) -> [Int] {
        let n = parent1.count
        let start = Int.random(in: 0..<n)
        let end = Int.random(in: start..<n)

        var child = [Int](repeating: -1, count: n)
        let segment = Set(parent1[start...end])

        // Copy segment from parent1
        for i in start...end {
            child[i] = parent1[i]
        }

        // Fill remaining positions from parent2 in order
        var pos = (end + 1) % n
        for gene in parent2 {
            guard !segment.contains(gene) else { continue }
            child[pos] = gene
            pos = (pos + 1) % n
        }

        return child
    }

    // MARK: - Mutation (Swap & Inversion)

    mutating func mutate(rate: Double, context: OptimizerContext) {
        guard sequence.count > 1 else { return }

        for _ in sequence.indices {
            guard Double.random(in: 0...1) < rate else { continue }
            needsEvaluation = true

            if Bool.random() {
                // Swap mutation: exchange two random positions
                let i = Int.random(in: 0..<sequence.count)
                var j = Int.random(in: 0..<sequence.count)
                while j == i { j = Int.random(in: 0..<sequence.count) }
                sequence.swapAt(i, j)
            } else {
                // Inversion mutation: reverse a random sub-segment
                let i = Int.random(in: 0..<sequence.count)
                let j = Int.random(in: i..<sequence.count)
                sequence[i...j].reverse()
            }
        }
    }
}

// MARK: - Pomodoro Sequence Evaluator

/// Evaluates PomodoroSequenceChromosome fitness based on task ordering quality.
/// Reuses logic from existing objectives (energy, context switch, deadline).
///
/// Supports two modes:
/// - **Weighted sum** (default): collapses four objectives into a scalar fitness.
/// - **Pareto-aware**: uses NSGA-II crowding distance to preserve diverse
///   non-dominated solutions, surfacing multiple distinct task orderings.
struct PomodoroSequenceEvaluator {

    /// Weights for the four sub-objectives.
    struct Weights: Sendable {
        var energyAlignment: Double = 0.30
        var contextSwitch: Double = 0.25
        var deadlineProximity: Double = 0.25
        var cognitiveLoad: Double = 0.20

        static let `default` = Weights()
    }

    let weights: Weights
    let sessionStart: Date
    let tasks: [OptimizableEvent]

    init(
        tasks: [OptimizableEvent],
        sessionStart: Date,
        weights: Weights = .default
    ) {
        self.tasks = tasks
        self.sessionStart = sessionStart
        self.weights = weights
    }

    /// Evaluate and assign fitness for the given chromosome.
    func evaluateAndAssign(
        _ chromosome: inout PomodoroSequenceChromosome,
        context: OptimizerContext
    ) {
        guard chromosome.needsEvaluation else { return }
        chromosome.fitness = evaluate(chromosome, context: context)
        chromosome.needsEvaluation = false
    }

    /// Compute fitness in [0, 1] for a task ordering (weighted sum).
    func evaluate(
        _ chromosome: PomodoroSequenceChromosome,
        context: OptimizerContext
    ) -> Double {
        let scores = objectiveScores(for: chromosome)

        return scores.energy * weights.energyAlignment
            + scores.context * weights.contextSwitch
            + scores.deadline * weights.deadlineProximity
            + scores.cognitive * weights.cognitiveLoad
    }

    /// Per-objective scores for a chromosome. Used by both weighted-sum and Pareto modes.
    func objectiveScores(
        for chromosome: PomodoroSequenceChromosome
    ) -> (energy: Double, context: Double, deadline: Double, cognitive: Double) {
        let ordered = chromosome.sequence.map { tasks[$0] }
        guard !ordered.isEmpty else { return (1.0, 1.0, 1.0, 1.0) }

        return (
            energy: evaluateEnergyCurve(ordered),
            context: evaluateContextSwitches(ordered),
            deadline: evaluateDeadlineProximity(ordered),
            cognitive: evaluateCognitiveLoad(ordered)
        )
    }

    // MARK: - Pareto Ranking (NSGA-II style)

    /// Assign fitness using Pareto dominance + crowding distance.
    /// Non-dominated individuals get highest fitness; within the same front,
    /// individuals in sparse regions score higher (preserving diversity).
    func evaluatePareto(
        _ population: inout [PomodoroSequenceChromosome]
    ) {
        guard !population.isEmpty else { return }

        // Compute objective vectors
        let objectiveVectors = population.map { chromosome -> [Double] in
            let s = objectiveScores(for: chromosome)
            return [s.energy, s.context, s.deadline, s.cognitive]
        }

        // Assign Pareto fronts
        let fronts = nonDominatedSort(objectiveVectors)

        // Assign fitness: front 0 (best) gets [0.8, 1.0], front 1 gets [0.6, 0.8], etc.
        let frontCount = max(1, fronts.count)
        for (frontIndex, front) in fronts.enumerated() {
            let frontBase = 1.0 - Double(frontIndex) / Double(frontCount)
            let frontRange = 1.0 / Double(frontCount)

            // Crowding distance within this front
            let distances = crowdingDistance(
                indices: front,
                objectiveVectors: objectiveVectors
            )

            // Normalize crowding distances to [0, 1]
            let maxDist = distances.max() ?? 1.0
            let normFactor = maxDist > 0 ? maxDist : 1.0

            for (i, idx) in front.enumerated() {
                let crowdingBonus = (distances[i] / normFactor) * frontRange * 0.9
                population[idx].fitness = max(0.01, frontBase - frontRange + crowdingBonus)
                population[idx].needsEvaluation = false
            }
        }
    }

    /// Non-dominated sorting: returns array of fronts (each front = array of indices).
    private func nonDominatedSort(_ objectives: [[Double]]) -> [[Int]] {
        let n = objectives.count
        var dominationCount = [Int](repeating: 0, count: n)
        var dominated: [[Int]] = Array(repeating: [], count: n)
        var fronts: [[Int]] = []
        var currentFront: [Int] = []

        for i in 0..<n {
            for j in 0..<n where i != j {
                if dominates(objectives[i], objectives[j]) {
                    dominated[i].append(j)
                } else if dominates(objectives[j], objectives[i]) {
                    dominationCount[i] += 1
                }
            }
            if dominationCount[i] == 0 {
                currentFront.append(i)
            }
        }

        while !currentFront.isEmpty {
            fronts.append(currentFront)
            var nextFront: [Int] = []
            for i in currentFront {
                for j in dominated[i] {
                    dominationCount[j] -= 1
                    if dominationCount[j] == 0 {
                        nextFront.append(j)
                    }
                }
            }
            currentFront = nextFront
        }

        return fronts
    }

    /// Returns true if `a` Pareto-dominates `b` (all objectives >= and at least one >).
    private func dominates(_ a: [Double], _ b: [Double]) -> Bool {
        var anyBetter = false
        for (va, vb) in zip(a, b) {
            if va < vb { return false }
            if va > vb { anyBetter = true }
        }
        return anyBetter
    }

    /// Crowding distance for individuals in a front.
    /// Measures how isolated each solution is in objective space — higher = more diverse.
    private func crowdingDistance(
        indices: [Int],
        objectiveVectors: [[Double]]
    ) -> [Double] {
        let count = indices.count
        guard count > 2 else {
            return [Double](repeating: Double.infinity, count: count)
        }

        let numObjectives = objectiveVectors[0].count
        var distances = [Double](repeating: 0, count: count)

        for m in 0..<numObjectives {
            // Sort indices by objective m
            let sorted = (0..<count).sorted {
                objectiveVectors[indices[$0]][m] < objectiveVectors[indices[$1]][m]
            }

            // Boundary solutions get infinite distance
            distances[sorted[0]] = .infinity
            distances[sorted[count - 1]] = .infinity

            let range = objectiveVectors[indices[sorted[count - 1]]][m]
                - objectiveVectors[indices[sorted[0]]][m]
            guard range > 0 else { continue }

            for i in 1..<(count - 1) {
                let prev = objectiveVectors[indices[sorted[i - 1]]][m]
                let next = objectiveVectors[indices[sorted[i + 1]]][m]
                distances[sorted[i]] += (next - prev) / range
            }
        }

        return distances
    }

    // MARK: - Sub-objectives

    /// High-energy tasks early in the session score better.
    /// Models energy as linearly declining from 1.0 to 0.3 across the session.
    private func evaluateEnergyCurve(
        _ ordered: [OptimizableEvent]
    ) -> Double {
        guard ordered.count > 1 else { return 1.0 }

        var score = 0.0
        let n = Double(ordered.count)

        for (position, task) in ordered.enumerated() {
            // Energy available at this position: 1.0 at start, 0.3 at end
            let positionFraction = Double(position) / (n - 1)
            let availableEnergy = 1.0 - positionFraction * 0.7

            // Alignment: high-cost tasks at high-energy positions
            let alignment = 1.0 - abs(task.energyCost - availableEnergy)
            score += alignment
        }

        return score / n
    }

    /// Fewer and lighter context switches between adjacent tasks = better.
    private func evaluateContextSwitches(_ ordered: [OptimizableEvent]) -> Double {
        guard ordered.count > 1 else { return 1.0 }

        var totalSeverity = 0.0
        for i in 0..<(ordered.count - 1) {
            let ctx1 = ordered[i].context ?? "__none__"
            let ctx2 = ordered[i + 1].context ?? "__none__"
            totalSeverity += ContextSwitchObjective.switchSeverity(from: ctx1, to: ctx2)
        }

        let maxSwitches = ordered.count - 1
        let switchRatio = totalSeverity / Double(maxSwitches)
        return exp(-switchRatio * 1.5)
    }

    /// Tasks with closer deadlines should appear earlier in the session.
    private func evaluateDeadlineProximity(_ ordered: [OptimizableEvent]) -> Double {
        let withDeadlines = ordered.enumerated().filter { $0.element.deadline != nil }
        guard !withDeadlines.isEmpty else { return 1.0 }

        var score = 0.0
        let n = Double(ordered.count)

        // Compute accumulated time offset for each position
        var timeOffset: TimeInterval = 0
        var offsets: [TimeInterval] = []
        for task in ordered {
            offsets.append(timeOffset)
            timeOffset += task.duration
        }

        for (position, task) in withDeadlines {
            guard let deadline = task.deadline else { continue }

            let taskStart = sessionStart.addingTimeInterval(offsets[position])
            let taskEnd = taskStart.addingTimeInterval(task.duration)
            let timeUntilDeadline = deadline.timeIntervalSince(taskEnd)

            if timeUntilDeadline < 0 {
                score += 0.0
            } else {
                let positionScore = 1.0 - (Double(position) / n)
                let urgency = 1.0 / (1.0 + timeUntilDeadline / 3600.0)
                score += positionScore * urgency + (1.0 - urgency) * 0.5
            }
        }

        return score / Double(withDeadlines.count)
    }

    /// Alternating heavy/light tasks prevents cognitive fatigue.
    /// Penalizes consecutive heavy tasks (energyCost > 0.6).
    private func evaluateCognitiveLoad(_ ordered: [OptimizableEvent]) -> Double {
        guard ordered.count > 1 else { return 1.0 }

        var consecutiveHeavy = 0
        var totalPenalty = 0.0

        for task in ordered {
            if task.energyCost > 0.6 {
                consecutiveHeavy += 1
                if consecutiveHeavy > 1 {
                    totalPenalty += Double(consecutiveHeavy - 1) * 0.15
                }
            } else {
                consecutiveHeavy = 0
            }
        }

        return max(0, 1.0 - totalPenalty)
    }
}

// MARK: - Pomodoro Sequence Optimizer

/// The result of a Pomodoro sequence optimization, including alternatives.
struct PomodoroSequenceResult: Sendable {
    /// The best task ordering (by weighted sum).
    let bestOrder: [OptimizableEvent]

    /// Alternative orderings from the Pareto front.
    /// Each represents a different trade-off between objectives.
    /// Empty when Pareto mode is disabled.
    let alternatives: [[OptimizableEvent]]

    /// Per-objective scores for the best ordering.
    let objectiveScores: (energy: Double, context: Double, deadline: Double, cognitive: Double)
}

/// Convenience wrapper that runs a GA to optimize task order within a Pomodoro session.
struct PomodoroSequenceOptimizer {

    /// Optimize the ordering of tasks within a Pomodoro session.
    /// Builds its own OptimizerContext from the provided tasks to guarantee
    /// that `context.movableEvents.count == tasks.count` (required for safe
    /// index-based permutation in PomodoroSequenceChromosome).
    ///
    /// Returns tasks in the optimized order.
    static func optimize(
        tasks: [OptimizableEvent],
        sessionStart: Date,
        preferences: OptimizerPreferences = OptimizerPreferences(),
        config: GAConfiguration = .quick,
        weights: PomodoroSequenceEvaluator.Weights = .default
    ) -> [OptimizableEvent] {
        optimizeWithAlternatives(
            tasks: tasks,
            sessionStart: sessionStart,
            preferences: preferences,
            config: config,
            weights: weights
        ).bestOrder
    }

    /// Optimize with Pareto-aware selection, returning both the best ordering
    /// and diverse alternatives that represent different objective trade-offs.
    static func optimizeWithAlternatives(
        tasks: [OptimizableEvent],
        sessionStart: Date,
        preferences: OptimizerPreferences = OptimizerPreferences(),
        config: GAConfiguration = .quick,
        weights: PomodoroSequenceEvaluator.Weights = .default,
        maxAlternatives: Int = 3
    ) -> PomodoroSequenceResult {
        guard tasks.count > 1 else {
            return PomodoroSequenceResult(
                bestOrder: tasks,
                alternatives: [],
                objectiveScores: (1.0, 1.0, 1.0, 1.0)
            )
        }

        let context = OptimizerContext(
            movableEvents: tasks,
            preferences: preferences
        )

        let evaluator = PomodoroSequenceEvaluator(
            tasks: tasks,
            sessionStart: sessionStart,
            weights: weights
        )

        let ga = GeneticAlgorithm<PomodoroSequenceChromosome>(
            config: config,
            context: context,
            evaluate: { chromosome in
                evaluator.evaluateAndAssign(&chromosome, context: context)
            }
        )

        var sorted = ga.run()

        // Apply Pareto ranking to final population to identify diverse solutions
        evaluator.evaluatePareto(&sorted)

        // Re-sort: Pareto ranking updates fitness with crowding distance
        sorted.sort { $0.fitness > $1.fitness }

        guard let best = sorted.first else {
            return PomodoroSequenceResult(
                bestOrder: tasks,
                alternatives: [],
                objectiveScores: (1.0, 1.0, 1.0, 1.0)
            )
        }

        let bestOrder = best.sequence.map { tasks[$0] }
        let bestScores = evaluator.objectiveScores(for: best)

        // Collect diverse alternatives (different from best)
        var alternatives: [[OptimizableEvent]] = []
        var seenSequences: Set<[Int]> = [best.sequence]

        for candidate in sorted.dropFirst() {
            guard alternatives.count < maxAlternatives else { break }
            guard !seenSequences.contains(candidate.sequence) else { continue }
            seenSequences.insert(candidate.sequence)
            alternatives.append(candidate.sequence.map { tasks[$0] })
        }

        return PomodoroSequenceResult(
            bestOrder: bestOrder,
            alternatives: alternatives,
            objectiveScores: bestScores
        )
    }
}
