import Foundation

// MARK: - Recipe Surface
//
// Derives which UI surfaces a recipe is reachable from, based on its existing
// properties — no new storage needed. Surfaces are computed on demand.
//
// Surfaces:
//  - .command     — reachable from the Cmd+K command palette (all recipes)
//  - .eventContext — reachable from the right-click menu on a specific event
//  - .freeSlot    — reachable from the + button on an empty time slot
//
// The Smart Banner surface is not modelled here — it's driven by
// `RecipeMonitor.suggestedRecipes` which already evaluates conditions.

extension ScheduleRecipe {

    // MARK: - Ready to execute

    /// A recipe is ready to execute if all required parameters have usable
    /// defaults. A recipe that requires an event pick (eventPicker/eventMultiPicker)
    /// can only be executed once the user has provided that context.
    var hasRequiredRuntimeInput: Bool {
        params.contains { param in
            switch param.kind {
            case .eventPicker, .eventMultiPicker, .text:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Event context applicability

    /// Whether this recipe applies to a specific existing event.
    /// Used to filter the recipes that appear in an event's right-click menu.
    func applies(to event: CalendarEvent) -> Bool {
        // Recipes with an explicit eventPicker always apply to any event
        if params.contains(where: { if case .eventPicker = $0.kind { return true } else { return false } }) {
            return true
        }

        // Recipes with eventRules that match event characteristics
        for rule in eventRules {
            switch rule.match {
            case .all:
                return true
            case .focusBlocks:
                if event.eventType == .pomodoro || event.title.localizedCaseInsensitiveContains("focus") {
                    return true
                }
            case .meetings:
                if event.meetingLink != nil || event.calendarName != nil {
                    return true
                }
            case .withDeadline:
                if event.isTask {
                    return true
                }
            case .longerThan(let minutes):
                if event.duration >= TimeInterval(minutes * 60) {
                    return true
                }
            case .id(let id):
                if event.id == id {
                    return true
                }
            case .ids(let ids):
                if ids.contains(event.id) {
                    return true
                }
            case .context, .highEnergy, .lowEnergy, .onDay, .onDays:
                continue
            }
        }

        return false
    }

    /// Returns a copy of the recipe with the given event preselected via placeholder
    /// substitution. If the recipe has an eventPicker param, the event id is bound to it.
    func withEventContext(_ event: CalendarEvent) -> ScheduleRecipe {
        var copy = self
        for param in params {
            switch param.kind {
            case .eventPicker:
                copy.applyParamValues([param.id: event.id])
            default:
                continue
            }
        }
        return copy
    }

    // MARK: - Free slot applicability

    /// Whether this recipe is suitable for filling an empty time slot.
    /// Creative recipes that only look for free slots (findSlotOnly) and fit within
    /// the given duration are eligible.
    func fitsInFreeSlot(minutes slotMinutes: Int) -> Bool {
        guard isCreative && findSlotOnly else { return false }
        // The recipe must have at least one event that fits.
        let minRequired = events.map(\.minutes).min() ?? 0
        return minRequired > 0 && minRequired <= slotMinutes
    }

    // MARK: - Search matching

    /// Lowercased matching across name, description, category and a few aliases.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if name.lowercased().contains(q) { return true }
        if description.lowercased().contains(q) { return true }
        if category.lowercased().contains(q) { return true }
        for alias in Self.searchAliases[id] ?? [] {
            if alias.contains(q) { return true }
        }
        return false
    }

    // MARK: - Schedule-Aware Preview

    /// Returns a short context-aware preview of what this recipe will do to
    /// the user's ACTUAL schedule, e.g. "09:30–11:30 · free slot available"
    /// instead of the generic description. Returns nil when no meaningful
    /// preview can be computed.
    func schedulePreview(reminderService: ReminderService, workingHours: ClosedRange<Int>) -> String? {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")

        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let todayEvents = reminderService.allEvents.filter {
            $0.startDate >= todayStart && $0.startDate < todayEnd
        }

        // Creative recipes (findSlotOnly) — show actual next free slot
        if findSlotOnly, let eventSpec = events.first {
            let needed = eventSpec.minutes
            let calEvents = todayEvents.sorted { $0.startDate < $1.startDate }
            guard let workStart = cal.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: now),
                  let workEnd = cal.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: now)
            else { return nil }
            let effectiveStart = max(workStart, now)
            guard effectiveStart < workEnd else {
                return "No working time left today"
            }

            var cursor = effectiveStart
            for event in calEvents where event.endDate > effectiveStart && event.startDate < workEnd {
                let eStart = max(event.startDate, effectiveStart)
                if eStart > cursor {
                    let gapMinutes = Int(eStart.timeIntervalSince(cursor) / 60)
                    if gapMinutes >= needed {
                        let slotEnd = cursor.addingTimeInterval(TimeInterval(needed * 60))
                        return "\(fmt.string(from: cursor))–\(fmt.string(from: slotEnd)) · \(needed) min slot"
                    }
                }
                cursor = max(cursor, event.endDate)
            }
            if cursor < workEnd {
                let gapMinutes = Int(workEnd.timeIntervalSince(cursor) / 60)
                if gapMinutes >= needed {
                    let slotEnd = cursor.addingTimeInterval(TimeInterval(needed * 60))
                    return "\(fmt.string(from: cursor))–\(fmt.string(from: slotEnd)) · \(needed) min slot"
                }
            }
            return "No \(needed)-min slot available today"
        }

        // Deadline recipes — count deadline tasks
        if conditions.contains(where: { if case .hasDeadlineWithin = $0 { return true } else { return false } }) {
            let deadlineTasks = reminderService.localEvents.filter { $0.endDate > now && $0.isTask }
            if deadlineTasks.isEmpty { return "No deadline tasks right now" }
            return "\(deadlineTasks.count) task\(deadlineTasks.count == 1 ? "" : "s") with upcoming deadline\(deadlineTasks.count == 1 ? "" : "s")"
        }

        // Meeting recipes — count meetings
        if conditions.contains(where: { if case .meetingHeavy = $0 { return true } else { return false } }) ||
           category == "meetings" {
            let meetingCount = todayEvents.filter { $0.meetingLink != nil || $0.calendarName != nil }.count
            if meetingCount == 0 { return "No meetings today" }
            return "\(meetingCount) meeting\(meetingCount == 1 ? "" : "s") today"
        }

        // Organizing recipes — count movable tasks
        if includeExistingEvents && events.isEmpty {
            let localToday = reminderService.localEvents.filter {
                $0.startDate >= now && $0.startDate < todayEnd && $0.isUpcoming
            }
            if localToday.isEmpty { return "No tasks to rearrange" }
            return "Will rearrange \(localToday.count) task\(localToday.count == 1 ? "" : "s")"
        }

        // Creative non-findSlotOnly recipes — show what gets created
        if !events.isEmpty {
            let totalBlocks = events.reduce(0) { $0 + $1.count }
            let totalMinutes = events.reduce(0) { $0 + $1.minutes * $1.count }
            if totalBlocks == 1 {
                return "Creates a \(totalMinutes)-min block"
            }
            return "Creates \(totalBlocks) blocks · \(totalMinutes) min total"
        }

        return nil
    }

    /// Hand-tuned extra aliases that map common intents to recipe ids.
    /// Keeps the user from having to know the exact recipe name.
    private static let searchAliases: [String: [String]] = [
        "need-focus": ["focus", "concentrate", "deep work", "free time", "quiet", "block off"],
        "pomodoro": ["pomodoro", "tomato", "25 min", "work sprint"],
        "structured-deep-work": ["deep work", "concentrate", "structured"],
        "deep-work-day": ["deep work day", "focus day"],
        "max-productivity": ["max productivity", "crunch", "grind"],
        "organize-day": ["organize", "rearrange", "sort", "tidy"],
        "plan-week": ["plan week", "week", "spread"],
        "full-rebuild": ["rebuild", "redo", "reset schedule"],
        "deadline-mode": ["deadline", "urgent", "due"],
        "deadline-crunch": ["crunch", "deadline", "urgent"],
        "batch-meetings": ["batch meetings", "group meetings"],
        "buffer-meetings": ["buffer", "break between meetings"],
        "prep-meeting": ["prep", "preparation", "before meeting"],
        "low-energy": ["tired", "low energy", "rest"],
        "morning-person": ["morning", "early"],
        "post-lunch-dip": ["afternoon slump", "post lunch"],
        "wind-down": ["wind down", "evening", "calm"],
        "lighten-tomorrow": ["lighten", "easy tomorrow"],
        "balance-week": ["balance", "distribute"],
        "free-friday": ["free friday", "long weekend"],
        "morning-routine": ["routine", "morning habit"],
        "evening-wrap-up": ["wrap up", "evening routine"],
        "regular-learning": ["learn", "study", "training"],
        "movement-reminders": ["stretch", "movement", "break", "walk"],
        "group-by-project": ["group", "project", "context"],
        "split-task": ["split", "break up", "divide"],
        "short-day": ["short day", "leave early"],
        "late-start": ["late start", "sleep in"],
        "wfh": ["home", "remote"],
        "circuit-training": ["workout", "circuit", "strength", "hiit"],
        "yoga-session": ["yoga", "stretch", "mobility"],
        "interval-training": ["hiit", "intervals", "cardio", "running"],
    ]
}
