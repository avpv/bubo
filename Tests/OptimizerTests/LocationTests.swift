import Foundation
import Testing
@testable import Bubo

// MARK: - Test Helpers

private let office = EventLocation(name: "Office", latitude: 55.7558, longitude: 37.6173)
private let coworking = EventLocation(name: "Coworking", latitude: 55.7400, longitude: 37.6500)
private let home = EventLocation(name: "Home", latitude: 55.7800, longitude: 37.5800)
// office ↔ coworking ≈ 2.7 km → ~5.4 min travel
// office ↔ home ≈ 4.5 km → ~9 min travel

private func makeContext(
    fixedEvents: [CalendarEvent] = [],
    movableEvents: [OptimizableEvent] = [],
    workingHours: ClosedRange<Int> = 9...18
) -> OptimizerContext {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

    return OptimizerContext(
        fixedEvents: fixedEvents,
        movableEvents: movableEvents,
        workingHours: workingHours,
        planningHorizon: DateInterval(start: today, end: tomorrow),
        preferences: OptimizerPreferences()
    )
}

private func makeGene(
    id: String,
    startHour: Int,
    startMinute: Int = 0,
    durationMinutes: Int = 60,
    location: EventLocation? = nil
) -> ScheduleGene {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let start = cal.date(bySettingHour: startHour, minute: startMinute, second: 0, of: today)!
    return ScheduleGene(
        eventId: id,
        title: "Event \(id)",
        startTime: start,
        duration: TimeInterval(durationMinutes * 60),
        context: nil,
        energyCost: 0.5,
        priority: 0.5,
        isFocusBlock: false,
        location: location
    )
}

// MARK: - EventLocation Tests

@Suite("EventLocation Tests")
struct EventLocationTests {

    @Test("Travel minutes between same location is zero")
    func sameLocationZeroTravel() {
        let travel = office.travelMinutes(to: office)
        #expect(travel == 0)
    }

    @Test("Travel minutes between nearby locations is positive")
    func nearbyLocationsPositiveTravel() {
        let travel = office.travelMinutes(to: coworking)
        #expect(travel > 0)
        #expect(travel < 30) // Should be a few minutes, not hours
    }

    @Test("Travel is symmetric")
    func travelIsSymmetric() {
        let ab = office.travelMinutes(to: home)
        let ba = home.travelMinutes(to: office)
        #expect(abs(ab - ba) < 0.001)
    }

    @Test("Very close locations have zero travel (under 0.5 km)")
    func veryCloseLocationsZeroTravel() {
        let a = EventLocation(name: "A", latitude: 55.7558, longitude: 37.6173)
        let b = EventLocation(name: "B", latitude: 55.7560, longitude: 37.6175)
        #expect(a.travelMinutes(to: b) == 0)
    }
}

// MARK: - TravelTimeObjective Tests

@Suite("TravelTimeObjective Tests")
struct TravelTimeObjectiveTests {

    @Test("No location events scores 1.0")
    func noLocationsScoresPerfect() {
        let objective = TravelTimeObjective()
        let genes = [
            makeGene(id: "1", startHour: 9),
            makeGene(id: "2", startHour: 10),
        ]
        let chromosome = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score == 1.0)
    }

    @Test("Same location events score 1.0")
    func sameLocationScoresPerfect() {
        let objective = TravelTimeObjective()
        let genes = [
            makeGene(id: "1", startHour: 9, location: office),
            makeGene(id: "2", startHour: 10, location: office),
        ]
        let chromosome = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score == 1.0)
    }

    @Test("Distant events with large gap score well")
    func distantEventsWithGapScoreWell() {
        let objective = TravelTimeObjective()
        let genes = [
            makeGene(id: "1", startHour: 9, location: office),
            makeGene(id: "2", startHour: 11, location: home), // 1 hour gap, ~9 min travel
        ]
        let chromosome = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score == 1.0)
    }

    @Test("Distant events with tiny gap score poorly")
    func distantEventsWithTinyGapScorePoorly() {
        let objective = TravelTimeObjective()
        let genes = [
            makeGene(id: "1", startHour: 9, location: office),
            makeGene(id: "2", startHour: 10, startMinute: 1, location: home), // 1 min gap, ~9 min travel
        ]
        let chromosome = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score < 0.5)
    }

    @Test("Empty chromosome scores 1.0")
    func emptyChromosomeScoresPerfect() {
        let objective = TravelTimeObjective()
        let chromosome = ScheduleChromosome(genes: [])
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score == 1.0)
    }
}

// MARK: - LocationBatchingObjective Tests

@Suite("LocationBatchingObjective Tests")
struct LocationBatchingObjectiveTests {

    @Test("All same location scores perfectly")
    func allSameLocationScoresPerfect() {
        let objective = LocationBatchingObjective()
        let genes = [
            makeGene(id: "1", startHour: 9, location: office),
            makeGene(id: "2", startHour: 10, location: office),
            makeGene(id: "3", startHour: 11, location: office),
        ]
        let chromosome = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score > 0.9)
    }

    @Test("Alternating locations scores poorly")
    func alternatingLocationsScoresPoorly() {
        let objective = LocationBatchingObjective()
        let genes = [
            makeGene(id: "1", startHour: 9, location: office),
            makeGene(id: "2", startHour: 10, location: home),
            makeGene(id: "3", startHour: 11, location: office),
            makeGene(id: "4", startHour: 12, location: home),
        ]
        let chromosome = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score < 0.5)
    }

    @Test("Batched locations scores better than alternating")
    func batchedScoresBetterThanAlternating() {
        let objective = LocationBatchingObjective()

        // Batched: office, office, home, home
        let batchedGenes = [
            makeGene(id: "1", startHour: 9, location: office),
            makeGene(id: "2", startHour: 10, location: office),
            makeGene(id: "3", startHour: 11, location: home),
            makeGene(id: "4", startHour: 12, location: home),
        ]
        let batchedChromosome = ScheduleChromosome(genes: batchedGenes)

        // Alternating: office, home, office, home
        let altGenes = [
            makeGene(id: "1", startHour: 9, location: office),
            makeGene(id: "2", startHour: 10, location: home),
            makeGene(id: "3", startHour: 11, location: office),
            makeGene(id: "4", startHour: 12, location: home),
        ]
        let altChromosome = ScheduleChromosome(genes: altGenes)

        let context = makeContext()
        let batchedScore = objective.evaluate(chromosome: batchedChromosome, context: context)
        let altScore = objective.evaluate(chromosome: altChromosome, context: context)

        #expect(batchedScore > altScore)
    }

    @Test("No location events scores 1.0")
    func noLocationsScoresPerfect() {
        let objective = LocationBatchingObjective()
        let genes = [
            makeGene(id: "1", startHour: 9),
            makeGene(id: "2", startHour: 10),
        ]
        let chromosome = ScheduleChromosome(genes: genes)
        let context = makeContext()

        let score = objective.evaluate(chromosome: chromosome, context: context)
        #expect(score == 1.0)
    }
}
