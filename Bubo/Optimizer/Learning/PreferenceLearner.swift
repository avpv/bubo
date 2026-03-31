import Foundation

// MARK: - #24 Preference Learner

/// Evolves objective weights based on user feedback (accept/reject/edit).
/// Uses a meta-GA to find the weight vector that best predicts user preferences.
final class PreferenceLearner {

    /// History of user feedback.
    private(set) var feedbackHistory: [UserFeedback] = []

    /// Current learned weights.
    private(set) var learnedWeights: [String: Double]

    /// Learning rate — how aggressively to update weights.
    var learningRate: Double = 0.1

    /// Minimum feedback samples before learning kicks in.
    var minSamplesForLearning: Int = 5

    /// Persistence key.
    private let persistenceKey = "BuboOptimizerLearnedWeights"
    private let feedbackKey = "BuboOptimizerFeedbackHistory"

    init() {
        self.learnedWeights = Self.defaultWeights
        load()
    }

    // MARK: - Default Weights

    static let defaultWeights: [String: Double] = [
        "FocusBlock": 1.0,
        "PomodoroFit": 0.8,
        "Conflict": 10.0,
        "TaskPlacement": 1.0,
        "WeekBalance": 0.8,
        "EnergyBalance": 0.9,
        "MultiPerson": 5.0,
        "BreakPlacement": 1.2,
        "Deadline": 3.0,
        "ContextSwitch": 0.7,
        "Buffer": 0.6,
    ]

    // MARK: - Record Feedback

    func recordAcceptance(scenarioFitness: Double) {
        feedbackHistory.append(.accepted(
            scenarioFitness: scenarioFitness,
            weights: learnedWeights
        ))
        learnIfReady()
        save()
    }

    func recordRejection(scenarioFitness: Double) {
        feedbackHistory.append(.rejected(
            scenarioFitness: scenarioFitness,
            weights: learnedWeights
        ))
        learnIfReady()
        save()
    }

    func recordModification(original: [ScheduleGene], edited: [ScheduleGene]) {
        feedbackHistory.append(.modified(
            originalGenes: original,
            editedGenes: edited,
            weights: learnedWeights
        ))
        learnIfReady()
        save()
    }

    // MARK: - Learning

    /// Run meta-GA to evolve weights if we have enough feedback.
    private func learnIfReady() {
        guard feedbackHistory.count >= minSamplesForLearning else { return }
        evolveWeights()
    }

    /// Meta-GA: evolve objective weights to match user preferences.
    private func evolveWeights() {
        let populationSize = 30
        let generations = 50
        let weightKeys = Array(learnedWeights.keys).sorted()

        // Create population of weight vectors
        var population: [[String: Double]] = []

        // Seed with current weights
        population.append(learnedWeights)

        // Create random mutations around current weights
        for _ in 1..<populationSize {
            var weights = learnedWeights
            for key in weightKeys {
                let current = weights[key] ?? 1.0
                let mutation = Double.random(in: -learningRate...learningRate) * current
                weights[key] = max(0.01, current + mutation)
            }
            population.append(weights)
        }

        // Evolve
        for _ in 0..<generations {
            // Evaluate fitness of each weight vector
            let scored = population.map { weights -> (weights: [String: Double], fitness: Double) in
                let fitness = evaluateWeightVector(weights)
                return (weights, fitness)
            }.sorted { $0.fitness > $1.fitness }

            // Select top half
            let survivors = Array(scored.prefix(populationSize / 2))

            // Create new population
            var newPop: [[String: Double]] = survivors.map(\.weights)

            // Crossover + mutation
            while newPop.count < populationSize {
                let parent1 = survivors.randomElement()!.weights
                let parent2 = survivors.randomElement()!.weights

                var child: [String: Double] = [:]
                for key in weightKeys {
                    // Blend crossover
                    let v1 = parent1[key] ?? 1.0
                    let v2 = parent2[key] ?? 1.0
                    let alpha = Double.random(in: 0...1)
                    var value = v1 * alpha + v2 * (1 - alpha)

                    // Mutation
                    if Double.random(in: 0...1) < 0.2 {
                        value += Double.random(in: -0.3...0.3) * value
                    }
                    child[key] = max(0.01, value)
                }
                newPop.append(child)
            }

            population = newPop
        }

        // Best weight vector
        let best = population.map { weights -> (weights: [String: Double], fitness: Double) in
            (weights, evaluateWeightVector(weights))
        }.max { $0.fitness < $1.fitness }

        if let bestWeights = best?.weights {
            learnedWeights = bestWeights
        }
    }

    /// Evaluate how well a weight vector predicts user preferences.
    private func evaluateWeightVector(_ weights: [String: Double]) -> Double {
        var score = 0.0

        for feedback in feedbackHistory {
            switch feedback {
            case .accepted(let fitness, let usedWeights):
                // Good: the weights that produced an accepted schedule should be similar
                let similarity = weightSimilarity(weights, usedWeights)
                score += fitness * similarity

            case .rejected(let fitness, let usedWeights):
                // Bad: the weights that produced a rejected schedule should be different
                let similarity = weightSimilarity(weights, usedWeights)
                score -= fitness * similarity * 0.5

            case .modified(_, _, let usedWeights):
                // Modified means "close but not quite" — slight penalty
                let similarity = weightSimilarity(weights, usedWeights)
                score += similarity * 0.3
            }
        }

        return score
    }

    /// Cosine similarity between two weight vectors.
    private func weightSimilarity(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let keys = Set(a.keys).union(b.keys)
        var dotProduct = 0.0
        var normA = 0.0
        var normB = 0.0

        for key in keys {
            let va = a[key] ?? 0
            let vb = b[key] ?? 0
            dotProduct += va * vb
            normA += va * va
            normB += vb * vb
        }

        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dotProduct / denom : 0
    }

    // MARK: - Apply to Preferences

    /// Convert learned weights to OptimizerPreferences updates.
    func applyToPreferences(_ preferences: inout OptimizerPreferences) {
        preferences.focusBlockWeight = learnedWeights["FocusBlock"] ?? preferences.focusBlockWeight
        preferences.pomodoroFitWeight = learnedWeights["PomodoroFit"] ?? preferences.pomodoroFitWeight
        preferences.conflictWeight = learnedWeights["Conflict"] ?? preferences.conflictWeight
        preferences.taskPlacementWeight = learnedWeights["TaskPlacement"] ?? preferences.taskPlacementWeight
        preferences.weekBalanceWeight = learnedWeights["WeekBalance"] ?? preferences.weekBalanceWeight
        preferences.energyCurveWeight = learnedWeights["EnergyBalance"] ?? preferences.energyCurveWeight
        preferences.multiPersonWeight = learnedWeights["MultiPerson"] ?? preferences.multiPersonWeight
        preferences.breakWeight = learnedWeights["BreakPlacement"] ?? preferences.breakWeight
        preferences.deadlineWeight = learnedWeights["Deadline"] ?? preferences.deadlineWeight
        preferences.contextSwitchWeight = learnedWeights["ContextSwitch"] ?? preferences.contextSwitchWeight
        preferences.bufferWeight = learnedWeights["Buffer"] ?? preferences.bufferWeight
    }

    // MARK: - Persistence

    private func save() {
        // Save learned weights
        if let data = try? JSONEncoder().encode(learnedWeights) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
        // Save recent feedback (keep last 100)
        let recent = Array(feedbackHistory.suffix(100))
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: feedbackKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let weights = try? JSONDecoder().decode([String: Double].self, from: data) {
            learnedWeights = weights
        }
        if let data = UserDefaults.standard.data(forKey: feedbackKey),
           let history = try? JSONDecoder().decode([UserFeedback].self, from: data) {
            feedbackHistory = history
        }
    }

    /// Reset all learned preferences to defaults.
    func reset() {
        learnedWeights = Self.defaultWeights
        feedbackHistory = []
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        UserDefaults.standard.removeObject(forKey: feedbackKey)
    }
}
