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

    /// Compute fitness in [0, 1] for a task ordering.
    func evaluate(
        _ chromosome: PomodoroSequenceChromosome,
        context: OptimizerContext
    ) -> Double {
        let ordered = chromosome.sequence.map { tasks[$0] }
        guard !ordered.isEmpty else { return 1.0 }

        let energyScore = evaluateEnergyCurve(ordered, context: context)
        let contextScore = evaluateContextSwitches(ordered)
        let deadlineScore = evaluateDeadlineProximity(ordered)
        let cognitiveScore = evaluateCognitiveLoad(ordered)

        return energyScore * weights.energyAlignment
            + contextScore * weights.contextSwitch
            + deadlineScore * weights.deadlineProximity
            + cognitiveScore * weights.cognitiveLoad
    }

    // MARK: - Sub-objectives

    /// High-energy tasks early in the session score better.
    /// Models energy as linearly declining from 1.0 to 0.3 across the session.
    private func evaluateEnergyCurve(
        _ ordered: [OptimizableEvent],
        context: OptimizerContext
    ) -> Double {
        guard ordered.count > 1 else { return 1.0 }

        var score = 0.0
        let n = Double(ordered.count)

        for (position, task) in ordered.enumerated() {
            // Energy available at this position: 1.0 at start, 0.3 at end
            let positionFraction = Double(position) / (n - 1)
            let availableEnergy = 1.0 - positionFraction * 0.7

            // Alignment: high-cost tasks at high-energy positions
            // Perfect alignment = energyCost matches availableEnergy rank order
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
                // Past deadline — strong penalty
                score += 0.0
            } else {
                // Earlier position for tighter deadlines = better
                let positionScore = 1.0 - (Double(position) / n)
                let urgency = 1.0 / (1.0 + timeUntilDeadline / 3600.0)
                // Urgent tasks in early positions score higher
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
        var maxConsecutiveHeavy = 0
        var totalPenalty = 0.0

        for task in ordered {
            if task.energyCost > 0.6 {
                consecutiveHeavy += 1
                maxConsecutiveHeavy = max(maxConsecutiveHeavy, consecutiveHeavy)
                if consecutiveHeavy > 1 {
                    // Penalty grows with each additional consecutive heavy task
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

/// Convenience wrapper that runs a GA to optimize task order within a Pomodoro session.
struct PomodoroSequenceOptimizer {

    /// Optimize the ordering of tasks within a Pomodoro session.
    /// Returns tasks in the optimized order.
    static func optimize(
        tasks: [OptimizableEvent],
        sessionStart: Date,
        context: OptimizerContext,
        config: GAConfiguration = .quick,
        weights: PomodoroSequenceEvaluator.Weights = .default
    ) -> [OptimizableEvent] {
        guard tasks.count > 1 else { return tasks }

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

        let sorted = ga.run()
        guard let best = sorted.first else { return tasks }

        return best.sequence.map { tasks[$0] }
    }
}
