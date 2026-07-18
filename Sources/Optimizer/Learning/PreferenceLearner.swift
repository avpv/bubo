import Foundation
import os
import BuboDomain

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "Optimizer/Learning")

// MARK: - #24 Preference Learner

/// Evolves objective weights based on user feedback (accept/reject/edit).
/// Uses a meta-GA to find the weight vector that best predicts user preferences.
public final class PreferenceLearner {

    /// History of user feedback.
    public private(set) var feedbackHistory: [UserFeedback] = []

    /// Current learned weights.
    public private(set) var learnedWeights: [String: Double]

    /// Learning rate — how aggressively to update weights.
    public var learningRate: Double = 0.1

    /// Minimum feedback samples before learning kicks in.
    public var minSamplesForLearning: Int = 5

    /// Persistence key.
    public let persistenceKey = "BuboOptimizerLearnedWeights"
    public let feedbackKey = "BuboOptimizerFeedbackHistory"

    /// Backing store for persistence. Injectable so tests can hand
    /// in an ephemeral suite — with a hardcoded `.standard`, every
    /// `PreferenceLearner()` in the test process inherited the
    /// feedback history saved by whichever test (or process) ran
    /// before it, so "fresh learner" assertions failed depending on
    /// suite order.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.learnedWeights = Self.defaultWeights
        load()
    }

    // MARK: - Default Weights

    public static let defaultWeights: [String: Double] = [
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
        "MeetingClustering": 0.8,
        "BacklogOrder": 0.5,
    ]

    // MARK: - Record Feedback

    public func recordAcceptance(scenarioFitness: Double) {
        feedbackHistory.append(.accepted(
            scenarioFitness: scenarioFitness,
            weights: learnedWeights
        ))
        logger.info("feedback_recorded kind=accepted fitness=\(scenarioFitness) total=\(self.feedbackHistory.count)")
        learnIfReady()
        save()
    }

    public func recordRejection(scenarioFitness: Double) {
        feedbackHistory.append(.rejected(
            scenarioFitness: scenarioFitness,
            weights: learnedWeights
        ))
        logger.info("feedback_recorded kind=rejected fitness=\(scenarioFitness) total=\(self.feedbackHistory.count)")
        learnIfReady()
        save()
    }

    public func recordModification(original: [ScheduleGene], edited: [ScheduleGene]) {
        feedbackHistory.append(.modified(
            originalGenes: original,
            editedGenes: edited,
            weights: learnedWeights
        ))
        logger.info("feedback_recorded kind=modified original_genes=\(original.count) edited_genes=\(edited.count) total=\(self.feedbackHistory.count)")
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
        let startedAt = Date()
        let weightsBefore = learnedWeights
        logger.info("learning_triggered kind=preference total_feedback=\(self.feedbackHistory.count) new_since_last=\(newFeedback)")
        evolveWeights()
        let deltas = self.learnedWeights
            .compactMap { key, value -> (String, Double)? in
                guard let prior = weightsBefore[key] else { return nil }
                let delta = value - prior
                return abs(delta) > 0.0001 ? (key, delta) : nil
            }
            .sorted { abs($0.1) > abs($1.1) }
            .prefix(3)
        let topDeltas = deltas.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.info("learning_completed kind=preference top_deltas=\(topDeltas, privacy: .public) duration_ms=\(durationMs)")
    }

    /// Meta-GA: evolve objective weights to match user preferences.
    private func evolveWeights() {
        let populationSize = 30
        let generations = 50
        let weightKeys = Array(learnedWeights.keys).sorted()

        var population: [[String: Double]] = []
        population.append(learnedWeights)

        for _ in 1..<populationSize {
            var weights = learnedWeights
            for key in weightKeys {
                let current = weights[key] ?? 1.0
                let mutation = Double.random(in: -learningRate...learningRate) * current
                weights[key] = max(0.01, current + mutation)
            }
            population.append(weights)
        }

        for _ in 0..<generations {
            let scored = population.map { weights -> (weights: [String: Double], fitness: Double) in
                let fitness = evaluateWeightVector(weights)
                return (weights, fitness)
            }.sorted { $0.fitness > $1.fitness }

            let survivors = Array(scored.prefix(populationSize / 2))

            var newPop: [[String: Double]] = survivors.map(\.weights)

            while newPop.count < populationSize {
                let parent1 = survivors.randomElement()!.weights
                let parent2 = survivors.randomElement()!.weights

                var child: [String: Double] = [:]
                for key in weightKeys {
                    let v1 = parent1[key] ?? 1.0
                    let v2 = parent2[key] ?? 1.0
                    let alpha = Double.random(in: 0...1)
                    var value = v1 * alpha + v2 * (1 - alpha)

                    if Double.random(in: 0...1) < 0.2 {
                        value += Double.random(in: -0.3...0.3) * value
                    }
                    child[key] = max(0.01, value)
                }
                newPop.append(child)
            }

            population = newPop
        }

        let best = population.map { weights -> (weights: [String: Double], fitness: Double) in
            (weights, evaluateWeightVector(weights))
        }.max { $0.fitness < $1.fitness }

        if let bestWeights = best?.weights {
            learnedWeights = bestWeights
        }
    }

    private func evaluateWeightVector(_ weights: [String: Double]) -> Double {
        var score = 0.0
        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else { return 0 }

        for feedback in feedbackHistory {
            switch feedback {
            case .accepted(let fitness, _):
                score += fitness

            case .rejected(let fitness, let usedWeights):
                let similarity = weightSimilarity(weights, usedWeights)
                score -= (1.0 - fitness) * similarity

            case .modified(let original, let edited, _):
                let editScore = editAlignmentScore(weights, original: original, edited: edited)
                score += editScore * 0.5
            }
        }

        return score
    }

    private func editAlignmentScore(
        _ weights: [String: Double],
        original: [ScheduleGene],
        edited: [ScheduleGene]
    ) -> Double {
        var alignmentScore = 0.0
        var comparisons = 0

        for editedGene in edited {
            guard let originalGene = original.first(where: { $0.eventId == editedGene.eventId }) else {
                continue
            }
            let shift = abs(editedGene.startTime.timeIntervalSince(originalGene.startTime))
            if shift > 0 {
                comparisons += 1
                alignmentScore += min(1.0, shift / 3600)
            }
        }

        return comparisons > 0 ? alignmentScore / Double(comparisons) : 0.5
    }

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
    public func applyToPreferences(_ preferences: inout OptimizerPreferences) {
        guard feedbackHistory.count >= minSamplesForLearning else { return }

        let blend = 0.3
        func blended(_ userWeight: Double, key: String) -> Double {
            guard let learned = learnedWeights[key] else { return userWeight }
            let defaultVal = Self.defaultWeights[key] ?? 1.0
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
        preferences.meetingClusteringWeight = blended(preferences.meetingClusteringWeight, key: "MeetingClustering")
        let resolvedBacklogOrder = preferences.backlogOrderWeight ?? OptimizerPreferences.defaultBacklogOrderWeight
        preferences.backlogOrderWeight = blended(resolvedBacklogOrder, key: "BacklogOrder")
    }

    // MARK: - Persistence

    /// Internal save hook — Bubo extends this class to also push to the
    /// cloud-sync bridge. Keeping the UserDefaults persistence here lets
    /// the optimizer target stand alone in tests that don't link Bubo.
    public func save() {
        if let data = try? JSONEncoder().encode(learnedWeights) {
            defaults.set(data, forKey: persistenceKey)
        }
        let recent = Array(feedbackHistory.suffix(100))
        if let data = try? JSONEncoder().encode(recent) {
            defaults.set(data, forKey: feedbackKey)
        }
    }

    public func load() {
        if let data = defaults.data(forKey: persistenceKey),
           let weights = try? JSONDecoder().decode([String: Double].self, from: data) {
            learnedWeights = weights
        }
        if let data = defaults.data(forKey: feedbackKey),
           let history = try? JSONDecoder().decode([UserFeedback].self, from: data) {
            feedbackHistory = history
        }
    }

    /// Reset all learned preferences to defaults.
    public func reset() {
        learnedWeights = Self.defaultWeights
        feedbackHistory = []
        defaults.removeObject(forKey: persistenceKey)
        defaults.removeObject(forKey: feedbackKey)
    }
}
