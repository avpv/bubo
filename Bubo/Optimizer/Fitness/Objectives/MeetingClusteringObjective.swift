import Foundation

// MARK: - Meeting Clustering Objective

/// Actively rewards schedules where movable meetings are clustered together,
/// creating large continuous focus blocks.
///
/// Unlike FocusBlockObjective (which passively scores existing gaps),
/// this objective specifically incentivizes *compressing* meetings into
/// dense clusters within a narrow time window, so the remaining day
/// has maximal uninterrupted time.
///
/// Scoring components:
///   - Cluster density (40%): how tightly meetings are packed
///   - Focus yield (35%): total free time in blocks >= 60 min created by clustering
///   - Fragmentation penalty (25%): penalizes scattered meetings across the day
struct MeetingClusteringObjective: FitnessObjective {
    let name = "MeetingClustering"
    var weight: Double

    /// Minimum gap between meetings to still count as same cluster (in seconds).
    let clusterGapThreshold: TimeInterval

    init(weight: Double = 0.8, clusterGapThresholdMinutes: Double = 15) {
        self.weight = weight
        self.clusterGapThreshold = clusterGapThresholdMinutes * 60
    }

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let cal = context.calendar

        // Collect all meetings (fixed + movable) grouped by day
        var meetingsByDay: [Date: [(start: Date, end: Date, isMovable: Bool)]] = [:]

        for event in context.fixedEvents {
            guard isMeeting(event) else { continue }
            let day = cal.startOfDay(for: event.startDate)
            meetingsByDay[day, default: []].append((event.startDate, event.endDate, event.isMovable))
        }
        for gene in chromosome.genes where !gene.isFocusBlock {
            let day = cal.startOfDay(for: gene.startTime)
            meetingsByDay[day, default: []].append((gene.startTime, gene.endTime, true))
        }

        guard !meetingsByDay.isEmpty else { return 1.0 }

        var totalScore = 0.0
        var dayCount = 0

        for (day, meetings) in meetingsByDay {
            guard meetings.count >= 2 else {
                totalScore += 1.0
                dayCount += 1
                continue
            }

            let sorted = meetings.sorted { $0.start < $1.start }

            let densityScore = clusterDensity(sorted)
            let focusScore = focusYield(
                meetings: sorted,
                day: day,
                workingHours: context.workingHours,
                calendar: cal
            )
            let fragmentationScore = 1.0 - fragmentationPenalty(sorted)
            let windowScore = clusterWindowAlignment(
                sorted,
                preferredStart: context.preferences.preferredClusterWindowStart,
                preferredEnd: context.preferences.preferredClusterWindowEnd,
                day: day,
                calendar: cal
            )
            let sizeScore = clusterSizeScore(
                sorted,
                maxPerCluster: context.preferences.maxMeetingsPerCluster
            )

            totalScore += densityScore * 0.30
                + focusScore * 0.25
                + fragmentationScore * 0.15
                + windowScore * 0.15
                + sizeScore * 0.15

            dayCount += 1
        }

        return dayCount > 0 ? totalScore / Double(dayCount) : 0.5
    }

    // MARK: - Cluster Density

    /// Measures how tightly meetings are packed together.
    /// Perfect density = meetings are back-to-back with gaps <= threshold.
    private func clusterDensity(
        _ meetings: [(start: Date, end: Date, isMovable: Bool)]
    ) -> Double {
        guard meetings.count > 1 else { return 1.0 }

        // Identify clusters: groups of meetings where each gap <= threshold
        let clusters = identifyClusters(meetings)

        // Score based on having fewer, larger clusters
        let largestCluster = clusters.map(\.count).max() ?? 1
        let clusterEfficiency = Double(largestCluster) / Double(meetings.count)

        // Bonus: total inter-meeting gap within clusters should be small
        var totalIntraGap: TimeInterval = 0
        var totalMeetingTime: TimeInterval = 0
        for cluster in clusters {
            for i in 0..<(cluster.count - 1) {
                let gap = cluster[i + 1].start.timeIntervalSince(cluster[i].end)
                totalIntraGap += max(0, gap)
            }
            for m in cluster {
                totalMeetingTime += m.end.timeIntervalSince(m.start)
            }
        }

        let packingRatio: Double
        if totalMeetingTime > 0 {
            // Ratio of actual meeting time to total cluster span
            packingRatio = totalMeetingTime / (totalMeetingTime + totalIntraGap)
        } else {
            packingRatio = 1.0
        }

        return clusterEfficiency * 0.6 + packingRatio * 0.4
    }

    // MARK: - Focus Yield

    /// Measures total high-quality focus time (blocks >= 60 min) created by the clustering.
    private func focusYield(
        meetings: [(start: Date, end: Date, isMovable: Bool)],
        day: Date,
        workingHours: ClosedRange<Int>,
        calendar: Calendar
    ) -> Double {
        guard let workStart = calendar.date(
            bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day
        ),
        let workEnd = calendar.date(
            bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day
        ) else { return 0.5 }

        let totalWorkMinutes = Double(workingHours.upperBound - workingHours.lowerBound) * 60.0
        guard totalWorkMinutes > 0 else { return 0.5 }

        // Find free gaps around meetings
        var gaps: [TimeInterval] = []
        var cursor = workStart

        for meeting in meetings {
            let mStart = max(meeting.start, workStart)
            let mEnd = min(meeting.end, workEnd)
            guard mStart < workEnd, mEnd > workStart else { continue }

            if mStart > cursor {
                gaps.append(mStart.timeIntervalSince(cursor))
            }
            cursor = max(cursor, mEnd)
        }
        if cursor < workEnd {
            gaps.append(workEnd.timeIntervalSince(cursor))
        }

        // Focus blocks: gaps >= 60 minutes
        let focusBlocks = gaps.filter { $0 >= 60 * 60 }
        let totalFocusMinutes = focusBlocks.reduce(0, +) / 60.0

        // Score: what fraction of the work day is quality focus time
        return min(1.0, totalFocusMinutes / (totalWorkMinutes * 0.6))
    }

    // MARK: - Fragmentation Penalty

    /// Penalizes meetings scattered across the day with large gaps between them.
    /// Returns a value in [0, 1] where 1 = maximally fragmented.
    /// Movable meetings that are isolated from clusters incur higher penalty.
    private func fragmentationPenalty(
        _ meetings: [(start: Date, end: Date, isMovable: Bool)]
    ) -> Double {
        guard meetings.count > 1 else { return 0.0 }

        // Measure the span from first meeting start to last meeting end
        let totalSpan = meetings.last!.end.timeIntervalSince(meetings.first!.start)
        guard totalSpan > 0 else { return 0.0 }

        // Total actual meeting time
        let totalMeetingTime = meetings.reduce(0.0) {
            $0 + $1.end.timeIntervalSince($1.start)
        }

        // Fragmentation = how much of the span is wasted on gaps
        let gapFraction = 1.0 - (totalMeetingTime / totalSpan)

        // Count distinct clusters — more clusters = more fragmented
        let clusters = identifyClusters(meetings)
        let clusterPenalty = Double(clusters.count - 1) * 0.15

        // Extra penalty for movable meetings sitting alone outside clusters
        let isolatedMovablePenalty = isolatedMovableFactor(clusters)

        return min(1.0, gapFraction * 0.5 + clusterPenalty * 0.25 + isolatedMovablePenalty * 0.25)
    }

    /// Extra penalty when movable meetings are isolated (not in the largest cluster).
    /// The GA can fix this by moving them, so penalizing drives convergence.
    private func isolatedMovableFactor(
        _ clusters: [[(start: Date, end: Date, isMovable: Bool)]]
    ) -> Double {
        guard clusters.count > 1 else { return 0.0 }

        let largestClusterIndex = clusters.enumerated()
            .max(by: { $0.element.count < $1.element.count })?.offset ?? 0

        var isolatedMovable = 0
        var totalMovable = 0

        for (idx, cluster) in clusters.enumerated() {
            for meeting in cluster where meeting.isMovable {
                totalMovable += 1
                if idx != largestClusterIndex {
                    isolatedMovable += 1
                }
            }
        }

        guard totalMovable > 0 else { return 0.0 }
        return Double(isolatedMovable) / Double(totalMovable)
    }

    // MARK: - Cluster Window Alignment

    /// Rewards meetings that fall within the user's preferred cluster window.
    /// E.g., if the user prefers meetings 9-13, meetings at 10:00 score high,
    /// meetings at 16:00 score low.
    private func clusterWindowAlignment(
        _ meetings: [(start: Date, end: Date, isMovable: Bool)],
        preferredStart: Int,
        preferredEnd: Int,
        day: Date,
        calendar: Calendar
    ) -> Double {
        guard !meetings.isEmpty,
              let windowStart = calendar.date(bySettingHour: preferredStart, minute: 0, second: 0, of: day),
              let windowEnd = calendar.date(bySettingHour: preferredEnd, minute: 0, second: 0, of: day)
        else { return 0.5 }

        var inWindow = 0
        for meeting in meetings {
            if meeting.start >= windowStart && meeting.end <= windowEnd {
                inWindow += 1
            }
        }

        return Double(inWindow) / Double(meetings.count)
    }

    // MARK: - Cluster Size Constraint

    /// Penalizes clusters that exceed the max meetings per cluster threshold.
    /// Marathon meeting blocks cause fatigue; splitting into smaller clusters is better.
    private func clusterSizeScore(
        _ meetings: [(start: Date, end: Date, isMovable: Bool)],
        maxPerCluster: Int
    ) -> Double {
        let clusters = identifyClusters(meetings)
        guard !clusters.isEmpty else { return 1.0 }

        var penalty = 0.0
        for cluster in clusters {
            let excess = max(0, cluster.count - maxPerCluster)
            penalty += Double(excess) * 0.2
        }

        return max(0, 1.0 - penalty)
    }

    // MARK: - Helpers

    /// Group meetings into clusters where consecutive meetings have gaps <= threshold.
    private func identifyClusters(
        _ meetings: [(start: Date, end: Date, isMovable: Bool)]
    ) -> [[(start: Date, end: Date, isMovable: Bool)]] {
        guard !meetings.isEmpty else { return [] }

        var clusters: [[(start: Date, end: Date, isMovable: Bool)]] = [[meetings[0]]]

        for i in 1..<meetings.count {
            let gap = meetings[i].start.timeIntervalSince(meetings[i - 1].end)
            if gap <= clusterGapThreshold {
                clusters[clusters.count - 1].append(meetings[i])
            } else {
                clusters.append([meetings[i]])
            }
        }

        return clusters
    }

    /// Heuristic: an event is a "meeting" if it has a meeting link
    /// or its title contains common meeting-related keywords.
    /// Pure duration-based guessing is avoided to prevent false positives
    /// (e.g., a 30-min personal task is not a meeting).
    private func isMeeting(_ event: CalendarEvent) -> Bool {
        if event.meetingLink != nil { return true }

        let title = event.title.lowercased()
        let meetingKeywords = ["meeting", "standup", "stand-up", "sync", "1:1",
                               "1-on-1", "review", "retro", "planning", "demo",
                               "interview", "call", "huddle"]
        return meetingKeywords.contains { title.contains($0) }
    }
}
