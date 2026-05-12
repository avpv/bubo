import Foundation
import BuboOptimizer

// MARK: - IntentCompiler optimizer-preferences builder
//
// Tail of the pipeline: turn the accumulated `ResolvedConfig` into the
// `OptimizerPreferences` value the GA engine consumes. Maps the high-
// level intent overrides (weights, peak energy hour, max meetings,
// lunch protection, working-days skipWeekends) onto the preferences
// fields. Extracted from `IntentCompiler.swift` so the preference-
// translation logic lives near `ResolvedConfig` (in `+Apply`) and
// next to the synthetic-event collection (in `+EventCollection`).

extension IntentCompiler {

    func buildPreferences(_ config: ResolvedConfig) -> OptimizerPreferences {
        var prefs = optimizer.preferences
        optimizer.preferenceLearner.applyToPreferences(&prefs)

        // Apply weight overrides from intents
        for (key, value) in config.weights {
            switch key {
            case .focusBlock:     prefs.focusBlockWeight = value
            case .pomodoroFit:    prefs.pomodoroFitWeight = value
            case .conflict:       prefs.conflictWeight = value
            case .taskPlacement:  prefs.taskPlacementWeight = value
            case .weekBalance:    prefs.weekBalanceWeight = value
            case .energyCurve:    prefs.energyCurveWeight = value
            case .multiPerson:    prefs.multiPersonWeight = value
            case .breakPlacement: prefs.breakWeight = value
            case .deadline:       prefs.deadlineWeight = value
            case .contextSwitch:  prefs.contextSwitchWeight = value
            case .buffer:         prefs.bufferWeight = value
            case .useLearned:     break
            }
        }

        // Apply direct preference overrides
        if let v = config.peakEnergyHour { prefs.peakEnergyHours = [v] }
        if let v = config.maxMeetingsPerDay { prefs.maxMeetingsPerDay = v }
        if let v = config.minBreakMinutes { prefs.minBreakMinutes = v }
        if let v = config.maxConsecutiveWorkMinutes { prefs.maxConsecutiveMeetingMinutes = v }
        if let v = config.meetingClusteringWeight { prefs.meetingClusteringWeight = v }
        if let v = config.lunchStart { prefs.lunchWindowStart = v }
        if let v = config.lunchEnd { prefs.lunchWindowEnd = v }
        // `.skipWeekends` intent is a convenience alias for "Mon–Fri only".
        // Translate it into the canonical `workingDays` override here so
        // the rest of the pipeline never has to juggle two representations.
        // Intent absent → leave the user's picker-configured set alone.
        if config.skipWeekends {
            prefs.workingDays = OptimizerPreferences.defaultWorkingDays
        }

        // Inject personal energy curve from check-in data when available.
        if let service = energyCheckInService, service.hasEnoughData {
            let cal = Calendar.current
            let now = Date()
            let dow = cal.component(.weekday, from: now)
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let meetingCount = reminderService.allEvents.filter {
                $0.startDate >= now && $0.startDate < todayEnd && !$0.isLocalEvent
            }.count
            prefs.personalEnergyCurve = service.predictedCurve(
                dayOfWeek: dow,
                meetingCount: meetingCount,
                defaultPeakHour: prefs.primaryPeakEnergyHour
            )
        }

        return prefs
    }
}
