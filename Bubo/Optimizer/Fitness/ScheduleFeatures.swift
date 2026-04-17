import Foundation

// MARK: - Schedule Feature Vector
//
// Single source of truth for "what does a chromosome look like as a
// short numeric vector?" Both the surrogate model and the
// Quality-Diversity behaviour descriptor read from this — keeping the
// extraction in one place means tweaking one feature updates both
// downstream consumers without drift.

/// Compact 16-dim feature vector describing a `ScheduleChromosome`.
/// Every component is normalized to `[0, 1]` so Euclidean distance
/// across components is meaningful for kNN-style consumers.
///
/// The first three components are the canonical Quality-Diversity
/// behaviour axes (`focusMass`, `morningSkew`, `daySpread`); the rest
/// are the surrogate's discriminative features. Keeping the QD axes at
/// fixed positions lets the archive read them by index without a
/// duplicate extraction pass.
struct ScheduleFeatureVector: Sendable {
    /// Fixed dimension. Stored on the type so consumers don't hard-code 16.
    static let dimension: Int = 16

    /// Index range of behaviour-descriptor axes within `values`.
    static let behaviorIndices = 0..<3

    /// Raw vector. Always exactly `dimension` long; values clamped to `[0, 1]`.
    let values: ContiguousArray<Double>

    init(_ values: ContiguousArray<Double>) {
        precondition(values.count == Self.dimension, "feature vector must be exactly \(Self.dimension)-dim")
        self.values = values
    }

    /// QD behaviour-axis slice. Reads `values[0..<3]`.
    var behavior: BehaviorDescriptor {
        BehaviorDescriptor(
            focusMass: values[0],
            morningSkew: values[1],
            daySpread: values[2]
        )
    }
}

extension ScheduleFeatureVector {
    /// Extract-or-reuse: returns the chromosome's cached feature
    /// vector when present, computing and caching otherwise. The
    /// chromosome must be passed `inout` because mutating the cache
    /// is the whole point of this overload.
    static func extractOrCache(
        _ chromosome: inout ScheduleChromosome,
        context: OptimizerContext
    ) -> ScheduleFeatureVector {
        if let cached = chromosome.cachedFeatures,
           cached.count == Self.dimension {
            return ScheduleFeatureVector(cached)
        }
        let vector = extract(chromosome, context: context)
        chromosome.cachedFeatures = vector.values
        return vector
    }

    /// Extract a feature vector from a chromosome. Visits each gene
    /// once and aggregates per-day / per-time-band statistics.
    static func extract(_ chromosome: ScheduleChromosome, context: OptimizerContext) -> ScheduleFeatureVector {
        let cal = context.calendar
        let horizon = context.planningHorizon
        let horizonStart = cal.startOfDay(for: horizon.start)
        let horizonLastDay = cal.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(
            1,
            (cal.dateComponents([.day], from: horizonStart, to: horizonLastDay).day ?? 0) + 1
        )
        let workHoursPerDay = max(1, context.workingHours.upperBound - context.workingHours.lowerBound)

        var includedCount = 0
        var totalDurationMinutes = 0.0
        var focusDurationMinutes = 0.0
        var energySum = 0.0
        var prioritySum = 0.0
        var startHourSum = 0.0
        var preLunchCount = 0
        var weekdayTouched = 0
        var daysUsed: Set<Date> = []
        var morningMassMinutes = 0.0
        var afternoonMassMinutes = 0.0
        var eveningMassMinutes = 0.0
        var firstStartOffset = Double.infinity
        var lastEndOffset = -Double.infinity
        var droppedCount = 0

        for gene in chromosome.genes {
            if !gene.isIncluded {
                if gene.isDroppable { droppedCount += 1 }
                continue
            }
            includedCount += 1
            let mins = gene.duration / 60.0
            totalDurationMinutes += mins
            if gene.isFocusBlock { focusDurationMinutes += mins }
            energySum += gene.energyCost
            prioritySum += gene.priority
            let hour = cal.component(.hour, from: gene.startTime)
            startHourSum += Double(hour)
            if hour < 12 { preLunchCount += 1 }

            let day = cal.startOfDay(for: gene.startTime)
            daysUsed.insert(day)
            let weekday = cal.component(.weekday, from: gene.startTime)
            if weekday >= 2 && weekday <= 6 { weekdayTouched += 1 }

            if hour < 12 { morningMassMinutes += mins }
            else if hour < 17 { afternoonMassMinutes += mins }
            else { eveningMassMinutes += mins }

            let startOffset = gene.startTime.timeIntervalSince(horizonStart)
            let endOffset = gene.endTime.timeIntervalSince(horizonStart)
            if startOffset < firstStartOffset { firstStartOffset = startOffset }
            if endOffset > lastEndOffset { lastEndOffset = endOffset }
        }

        let totalGenes = max(1, chromosome.genes.count)
        let includedFrac = Double(includedCount) / Double(totalGenes)
        let meanMinutes = includedCount > 0 ? totalDurationMinutes / Double(includedCount) : 0
        let focusFrac = totalDurationMinutes > 0 ? focusDurationMinutes / totalDurationMinutes : 0
        let meanEnergy = includedCount > 0 ? energySum / Double(includedCount) : 0
        let meanPriority = includedCount > 0 ? prioritySum / Double(includedCount) : 0
        let meanStartHour = includedCount > 0 ? startHourSum / Double(includedCount) : 0
        let preLunchFrac = includedCount > 0 ? Double(preLunchCount) / Double(includedCount) : 0
        let weekdayFrac = includedCount > 0 ? Double(weekdayTouched) / Double(includedCount) : 0
        let daySpread = Double(daysUsed.count) / Double(daysInHorizon)

        let morningFrac = totalDurationMinutes > 0 ? morningMassMinutes / totalDurationMinutes : 0
        let afternoonFrac = totalDurationMinutes > 0 ? afternoonMassMinutes / totalDurationMinutes : 0
        let eveningFrac = totalDurationMinutes > 0 ? eveningMassMinutes / totalDurationMinutes : 0

        let loadRatio = includedCount > 0
            ? (totalDurationMinutes / 60.0) / (Double(workHoursPerDay) * Double(max(1, daysUsed.count)))
            : 0

        let horizonSeconds = max(1, horizon.duration)
        let firstStartNorm = firstStartOffset.isFinite ? max(0, min(1, firstStartOffset / horizonSeconds)) : 0
        let lastEndNorm = lastEndOffset.isFinite ? max(0, min(1, lastEndOffset / horizonSeconds)) : 0

        let droppedFrac = Double(droppedCount) / Double(totalGenes)

        // Layout: behaviour axes first (focusMass, morningSkew,
        // daySpread), then 13 surrogate-discriminative features.
        var v = ContiguousArray<Double>()
        v.reserveCapacity(Self.dimension)
        v.append(clamp(focusFrac))         //  0: focusMass [QD axis]
        v.append(clamp(preLunchFrac))      //  1: morningSkew [QD axis]
        v.append(clamp(daySpread))         //  2: daySpread [QD axis]
        v.append(clamp(includedFrac))      //  3
        v.append(clamp(meanEnergy))        //  4
        v.append(clamp(meanPriority))      //  5
        v.append(clamp(meanStartHour / 24)) //  6
        v.append(clamp(weekdayFrac))       //  7
        v.append(clamp(morningFrac))       //  8
        v.append(clamp(afternoonFrac))     //  9
        v.append(clamp(eveningFrac))       // 10
        v.append(clamp(loadRatio))         // 11
        v.append(clamp(firstStartNorm))    // 12
        v.append(clamp(lastEndNorm))       // 13
        v.append(clamp(droppedFrac))       // 14
        v.append(clamp(min(1, meanMinutes / 240))) // 15
        return ScheduleFeatureVector(v)
    }

    @inline(__always)
    private static func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
}
