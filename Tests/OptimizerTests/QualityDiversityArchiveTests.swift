import Foundation
import Testing
@testable import Bubo

@Suite("Quality-Diversity Archive (MAP-Elites)")
struct QualityDiversityArchiveTests {

    @Test("New cells are always accepted")
    func freshCellsAccepted() {
        let archive = QualityDiversityArchive(resolution: 4)
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [OptimizerTestFixtures.makeEvent(id: "t1"), OptimizerTestFixtures.makeEvent(id: "t2")]
        )
        var chromo = ScheduleChromosome.random(context: context)
        chromo.rawFitness = 0.7
        let descriptor = BehaviorDescriptor.from(chromo, context: context)
        let (inserted, _) = archive.consider(chromo, descriptor: descriptor)
        #expect(inserted)
        #expect(archive.count == 1)
    }

    @Test("Better incumbents replace existing ones")
    func betterIncumbentsReplace() {
        let archive = QualityDiversityArchive(resolution: 4)
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [OptimizerTestFixtures.makeEvent(id: "t1")]
        )
        var chromo = ScheduleChromosome.random(context: context)
        chromo.rawFitness = 0.5
        let descriptor = BehaviorDescriptor.from(chromo, context: context)
        archive.consider(chromo, descriptor: descriptor)

        var better = chromo
        better.rawFitness = 0.8
        let (inserted, delta) = archive.consider(better, descriptor: descriptor)
        #expect(inserted)
        #expect(delta > 0)
        #expect(archive.count == 1)
    }

    @Test("Worse incumbents are rejected")
    func worseIncumbentsRejected() {
        let archive = QualityDiversityArchive(resolution: 4)
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: [OptimizerTestFixtures.makeEvent(id: "t1")]
        )
        var chromo = ScheduleChromosome.random(context: context)
        chromo.rawFitness = 0.8
        let descriptor = BehaviorDescriptor.from(chromo, context: context)
        archive.consider(chromo, descriptor: descriptor)

        var worse = chromo
        worse.rawFitness = 0.3
        let (inserted, _) = archive.consider(worse, descriptor: descriptor)
        #expect(!inserted)
    }

    @Test("Emitter sampling returns cached incumbents")
    func emitterSamplingProducesIncumbents() {
        let archive = QualityDiversityArchive(resolution: 3)
        let context = OptimizerTestFixtures.makeContext(
            movableEvents: (0..<5).map { OptimizerTestFixtures.makeEvent(id: "t\($0)") }
        )
        for i in 0..<8 {
            var chromo = ScheduleChromosome.random(context: context)
            chromo.rawFitness = Double(i) * 0.1
            let descriptor = BehaviorDescriptor.from(chromo, context: context)
            archive.consider(chromo, descriptor: descriptor)
        }
        let emitters = archive.drawEmitters(count: 3, rng: GARandom(seed: 99))
        #expect(emitters.count <= 3)
        #expect(emitters.count >= 1)
    }
}
