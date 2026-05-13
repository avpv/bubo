import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

@Suite("Schedule Gradient Refiner (Finite Difference)")
struct ScheduleGradientRefinerTests {

    @Test("Refiner never worsens the input chromosome")
    func refinerMonotonic() {
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [
                OptimizerTestFixtures.makeEvent(id: "t1", durationMinutes: 60),
                OptimizerTestFixtures.makeEvent(id: "t2", durationMinutes: 45)
            ]
        )
        var chromo = ScheduleChromosome.random(context: context)

        // Synthetic evaluator: fitness peaks at 10am on the first gene.
        let evaluator: (inout ScheduleChromosome) -> Void = { c in
            guard let first = c.genes.first else {
                c.rawFitness = 0
                c.fitness = 0
                return
            }
            let cal = Calendar.current
            let day = cal.startOfDay(for: first.startTime)
            let target = cal.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
            let diff = abs(first.startTime.timeIntervalSince(target))
            let fit = 1.0 / (1.0 + diff / 3600.0)
            c.rawFitness = fit
            c.fitness = fit
        }

        evaluator(&chromo)
        let initialFitness = chromo.rawFitness
        let refiner = ScheduleGradientRefiner(config: .default)
        let delta = refiner.refine(&chromo, context: context, evaluate: evaluator)
        #expect(delta >= 0)
        #expect(chromo.rawFitness >= initialFitness)
    }
}
