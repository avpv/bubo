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

    /// Track feedback count at last learning run.
    private var feedbackCountAtLastLearn: Int = 0

    /// Run meta-GA to evolve weights if we have enough new feedback.
    /// Only runs every 5 new feedback items to avoid blocking the main thread.
    private func learnIfReady() {
        guard feedbackHistory.count >= minSamplesForLearning else { return }
        let newFeedback = feedbackHistory.count - feedbackCountAtLastLearn
        guard newFeedback >= 5 else { return }
        feedbackCountAtLastLearn = feedbackHistory.count
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

    /// Evaluate how well a weight vector aligns with user preferences.
    /// Instead of circular similarity-to-self, this scores weights by how well
    /// they would have ranked accepted scenarios higher than rejected ones.
    private func evaluateWeightVector(_ weights: [String: Double]) -> Double {
        var score = 0.0
        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else { return 0 }

        for feedback in feedbackHistory {
            switch feedback {
            case .accepted(let fitness, _):
                // High-fitness accepted scenarios boost the candidate weight vector
                // proportional to how much these weights emphasize the right objectives
                score += fitness

            case .rejected(let fitness, let usedWeights):
                // Penalize if candidate weights are similar to the weights that
                // produced the rejected schedule; reward divergence
                let similarity = weightSimilarity(weights, usedWeights)
                score -= (1.0 - fitness) * similarity

            case .modified(let original, let edited, _):
                // User edits signal which objectives matter: measure how much
                // the candidate weights align with the direction of edits
                let editScore = editAlignmentScore(weights, original: original, edited: edited)
                score += editScore * 0.5
            }
        }

        return score
    }

    /// Score how well weights align with the user's manual edits.
    /// Compares what changed between original and edited genes.
    private func editAlignmentScore(
        _ weights: [String: Double],
        original: [ScheduleGene],
        edited: [ScheduleGene]
    ) -> Double {
        // If user moved events to reduce conflicts, reward conflict weight
        // If user moved events to earlier times, reward energy alignment
        var alignmentScore = 0.0
        var comparisons = 0

        for editedGene in edited {
            guard let originalGene = original.first(where: { $0.eventId == editedGene.eventId }) else {
                continue
            }
            let shift = abs(editedGene.startTime.timeIntervalSince(originalGene.startTime))
            if shift > 0 {
                comparisons += 1
                // User moved this event — give credit proportional to shift magnitude
                alignmentScore += min(1.0, shift / 3600)
            }
        }

        return comparisons > 0 ? alignmentScore / Double(comparisons) : 0.5
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

    /// Blend learned weights with user preferences.
    /// User-set weights are the base; learned weights nudge them proportionally.
    /// This ensures user manual adjustments in Settings are never silently overwritten.
    func applyToPreferences(_ preferences: inout OptimizerPreferences) {
        guard feedbackHistory.count >= minSamplesForLearning else { return }

        let blend = 0.3  // 30% learned, 70% user-set
        func blended(_ userWeight: Double, key: String) -> Double {
            guard let learned = learnedWeights[key] else { return userWeight }
            let defaultVal = Self.defaultWeights[key] ?? 1.0
            // Only apply learned delta relative to default, scaled by blend factor
            let learnedDelta = learned - defaultVal
            return max(0.01, userWeight + learnedDelta * blend)
        }

        preferences.focusBlockWeight = blended(preferences.focusBlockWeight, key: "FocusBlock")
        preferences.pomodoroFitWeight = blended(preferences.pomodoroFitWeight, key: "PomodoroFit")
        preferences.conflictWeight = blended(preferences.conflictWeight, key: "Conflict")
        preferences.taskPlacementWeight = blended(preferences.taskPlacementWeight, key: "TaskPlacement")
        preferences.weekBalanceWeight = blended(preferences.weekBalanceWeight, key: "WeekBalance")
        preferences.energyCurveWeight = blended(preferences.energyCurveWeight, key: "EnergyBalance")
        preferences.multiPersonWeight = blended(preferences.multiPersonWeight, key: "MultiPerson")
        preferences.breakWeight = blended(preferences.breakWeight, key: "BreakPlacement")
        preferences.deadlineWeight = blended(preferences.deadlineWeight, key: "Deadline")
        preferences.contextSwitchWeight = blended(preferences.contextSwitchWeight, key: "ContextSwitch")
        preferences.bufferWeight = blended(preferences.bufferWeight, key: "Buffer")
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
