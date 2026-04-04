import Foundation

// MARK: - Recipe Catalog

/// Registry of all available recipes, organized by category.
/// Adding a new recipe = adding a new static property. Zero code changes elsewhere.
struct RecipeCatalog {

    // MARK: - Quick Actions (shown prominently)

    static let quickActions: [ScheduleRecipe] = [
        .needFocus(), .organizeDay, .deadlineMode,
        .pomodoroSession(), .planWeek, .lowEnergyDay,
    ]

    // MARK: - All Categories

    struct Category: Identifiable {
        let id: String
        let name: String
        let recipes: [ScheduleRecipe]
    }

    static let allCategories: [Category] = [
        Category(id: "focus", name: "Focus & Deep Work", recipes: [
            .needFocus(), .pomodoroSession(), .structuredDeepWork(),
            .deepWorkDay(), .maxProductivity,
        ]),
        Category(id: "planning", name: "Planning", recipes: [
            .organizeDay, .planWeek, .fullRebuild,
        ]),
        Category(id: "deadlines", name: "Deadlines", recipes: [
            .deadlineMode, .deadlineCrunch, .multipleDeadlines,
        ]),
        Category(id: "meetings", name: "Meetings", recipes: [
            .batchMeetings, .bufferBetweenMeetings(),
            .tooManyMeetings, .prepBeforeMeeting(),
        ]),
        Category(id: "energy", name: "Energy & Balance", recipes: [
            .lowEnergyDay, .morningPerson, .postLunchDip,
            .windDownLastHour, .lightenTomorrow,
            .balanceWeek, .focusMeetingSplit, .freeFriday,
        ]),
        Category(id: "habits", name: "Habits & Routine", recipes: [
            .morningRoutine(), .eveningWrapUp(), .regularLearning(),
            .movementReminders,
        ]),
        Category(id: "projects", name: "Projects", recipes: [
            .groupByProject, .prioritizeProject(),
            .splitLargeTask(), .alternateTaskTypes,
            .carryOverUnfinished,
        ]),
        Category(id: "adapt", name: "Day Adjustments", recipes: [
            .shortDay(), .lateStart(), .workFromHome,
            .halfDayBlocked, .optimizeMorningOnly,
            .noMeetingsBefore(),
        ]),
        Category(id: "workouts", name: "Workouts & Activities", recipes: [
            .circuitTraining(), .yogaSession(), .intervalTraining(),
        ]),
        Category(id: "work-styles", name: "Work Styles", recipes: [
            .showOptions, .likeYesterday, .makerSchedule, .managerSchedule,
        ]),
    ]

    // MARK: - All Recipes (flat lookup)

    /// All user-facing recipes indexed by ID for fast lookup.
    static let allRecipesById: [String: ScheduleRecipe] = {
        var map: [String: ScheduleRecipe] = [:]
        for recipe in quickActions { map[recipe.id] = recipe }
        for category in allCategories {
            for recipe in category.recipes { map[recipe.id] = recipe }
        }
        return map
    }()

    // MARK: - Reaction Recipes (auto-triggered)

    static let reactions: [ScheduleRecipe] = [
        .onEventDeleted, .onEventMoved, .onEventCreated,
    ]
}

// MARK: - Preset Recipes

extension ScheduleRecipe {

    // ═══════════════════════════════════════════════════════
    // FOCUS & DEEP WORK
    // ═══════════════════════════════════════════════════════

    static func needFocus(minutes: Int = 120) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "need-focus",
            name: "Need Focus",
            description: "Finds a free slot and creates a focus event",
            category: "focus",
            events: [
                EventSpec(title: "Focus Time", minutes: minutes,
                         priority: 0.9, energy: 0.7,
                         period: .morning, focus: true),
            ],
            findSlotOnly: true,
            weights: [.focusBlock: 2.0],
            params: [
                RecipeParam(id: "minutes", label: "How long?",
                           kind: .segmented(Array(stride(from: 30, through: 480, by: 30))),
                           target: .eventMinutes(index: 0)),
                RecipeParam(id: "period", label: "When?",
                           kind: .periodPicker,
                           target: .eventPeriod(index: 0)),
            ]
        )
    }

    static func pomodoroSession(preset: PomodoroPreset = .classic) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "pomodoro",
            name: "Pomodoro Session",
            description: "Finds a free slot and creates a pomodoro session",
            category: "focus",
            events: [
                EventSpec(title: "Pomodoro Session", minutes: preset.totalMinutes,
                         priority: 0.7, energy: 0.8,
                         period: .morning, focus: true, pomodoro: preset),
            ],
            findSlotOnly: true,
            weights: [.pomodoroFit: 1.5, .energyCurve: 1.5],
            params: [
                RecipeParam(id: "period", label: "When?",
                           kind: .periodPicker,
                           target: .eventPeriod(index: 0)),
            ]
        )
    }

    static func structuredDeepWork(minutes: Int = 130) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "structured-deep-work",
            name: "Structured Deep Work",
            description: "Finds a free slot and creates a focus block with pomodoro intervals",
            category: "focus",
            events: [
                EventSpec(title: "Deep Work", minutes: minutes,
                         priority: 0.9, energy: 0.8,
                         period: .morning, focus: true, pomodoro: .classic),
            ],
            findSlotOnly: true,
            weights: [.focusBlock: 2.5, .pomodoroFit: 2.0],
            params: [
                RecipeParam(id: "minutes", label: "Total time",
                           kind: .segmented([90, 120, 130, 180]),
                           target: .eventMinutes(index: 0)),
                RecipeParam(id: "period", label: "When?",
                           kind: .periodPicker,
                           target: .eventPeriod(index: 0)),
            ]
        )
    }

    static func deepWorkDay(count: Int = 2, minutes: Int = 120) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "deep-work-day",
            name: "Deep Work Day",
            description: "Creates focus block events and rearranges tasks around them",
            category: "focus",
            events: [
                EventSpec(title: "Focus Block", minutes: minutes, count: count,
                         priority: 0.95, energy: 0.7, focus: true),
            ],
            weights: [.focusBlock: 3.0, .contextSwitch: 1.5, .energyCurve: 1.5],
            params: [
                RecipeParam(id: "count", label: "Blocks",
                           kind: .segmented([1, 2, 3, 4]),
                           target: .eventCount(index: 0)),
                RecipeParam(id: "minutes", label: "Duration",
                           kind: .segmented([60, 90, 120, 180]),
                           target: .eventMinutes(index: 0)),
            ]
        )
    }

    static let maxProductivity = ScheduleRecipe(
        id: "max-productivity",
        name: "Max Productivity",
        description: "Creates 3 deep work events, limits meetings to 2/day",
        category: "focus",
        events: [
            EventSpec(title: "Deep Work", minutes: 120, count: 3,
                     priority: 0.95, energy: 0.7, focus: true),
        ],
        weights: [.focusBlock: 3.0, .contextSwitch: 2.0, .energyCurve: 2.0],
        params: [
            RecipeParam(id: "maxMeetings", label: "Max meetings/day",
                       kind: .segmented([1, 2, 3, 4, 5]),
                       target: .maxMeetings),
        ],
        maxMeetingsPerDay: 2
    )

    // ═══════════════════════════════════════════════════════
    // PLANNING
    // ═══════════════════════════════════════════════════════

    static let organizeDay = ScheduleRecipe(
        id: "organize-day",
        name: "Organize Day",
        description: "Moves tasks to reduce context switches and match energy",
        category: "planning",
        weights: [.energyCurve: 1.5, .contextSwitch: 1.2],
        params: [
            RecipeParam(id: "events", label: "Which tasks to organize?",
                       kind: .eventMultiPicker, target: .selectedEventIds),
        ]
    )

    static let planWeek = ScheduleRecipe(
        id: "plan-week",
        name: "Plan Week",
        description: "Spreads tasks evenly across days of the week",
        category: "planning",
        horizon: .week,
        weights: [.weekBalance: 1.5, .energyCurve: 1.5],
        speed: .balanced,
        params: [
            RecipeParam(id: "events", label: "Which tasks to plan?",
                       kind: .eventMultiPicker, target: .selectedEventIds),
            RecipeParam(id: "horizon", label: "Time range",
                       kind: .horizonPicker, target: .horizon),
        ]
    )

    static let fullRebuild = ScheduleRecipe(
        id: "full-rebuild",
        name: "Full Rebuild",
        description: "Rebuilds the entire week schedule from scratch",
        category: "planning",
        horizon: .week,
        stability: .full,
        speed: .thorough,
        params: [
            RecipeParam(id: "events", label: "Which tasks to rebuild?",
                       kind: .eventMultiPicker, target: .selectedEventIds),
        ]
    )

    // ═══════════════════════════════════════════════════════
    // DEADLINES
    // ═══════════════════════════════════════════════════════

    static let deadlineMode = ScheduleRecipe(
        id: "deadline-mode",
        name: "Deadline Mode",
        description: "Moves deadline tasks first, pushes the rest aside",
        category: "deadlines",
        weights: [.deadline: 8.0, .breakPlacement: 0.6,
                  .buffer: 0.3, .contextSwitch: 0.2],
        speed: .balanced,
        eventRules: [
            EventRule(match: .withDeadline, action: .setPriority(1.0)),
        ],
        conditions: [.hasDeadlineWithin(days: 3)]
    )

    static let deadlineCrunch = ScheduleRecipe(
        id: "deadline-crunch",
        name: "Deadline Crunch",
        description: "Drops low-priority tasks, fills the day with deadline work",
        category: "deadlines",
        weights: [.deadline: 10.0, .breakPlacement: 0.3, .buffer: 0.1],
        speed: .balanced,
        eventRules: [
            EventRule(match: .withDeadline, action: .setPriority(1.0)),
            EventRule(match: .lowEnergy, action: .exclude),
        ],
        conditions: [.hasDeadlineWithin(days: 1)],
        params: [
            RecipeParam(id: "minBreak", label: "Min break between tasks",
                       kind: .segmented([0, 5, 10, 15]),
                       target: .minBreak),
        ],
        minBreakMinutes: 5
    )

    static let multipleDeadlines = ScheduleRecipe(
        id: "multiple-deadlines",
        name: "Multiple Deadlines",
        description: "Distributes deadline tasks across the week by urgency",
        category: "deadlines",
        horizon: .week,
        weights: [.deadline: 5.0, .weekBalance: 1.5],
        speed: .thorough,
        eventRules: [
            EventRule(match: .withDeadline, action: .setPriority(0.9)),
        ],
        conditions: [.hasDeadlineWithin(days: 7)]
    )

    // ═══════════════════════════════════════════════════════
    // MEETINGS
    // ═══════════════════════════════════════════════════════

    static let batchMeetings = ScheduleRecipe(
        id: "batch-meetings",
        name: "Batch Meetings",
        description: "Moves meetings into one block to free up focus time",
        category: "meetings",
        weights: [.contextSwitch: 4.0],
        eventRules: [
            EventRule(match: .meetings, action: .setPreferredPeriod(.morning)),
        ]
    )

    static func bufferBetweenMeetings(minutes: Int = 15) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "buffer-meetings",
            name: "Buffer Between Meetings",
            description: "Adds \(minutes)-min breaks between back-to-back meetings",
            category: "meetings",
            horizon: .week,
            weights: [.buffer: 2.0],
            speed: .balanced,
            params: [
                RecipeParam(id: "minutes", label: "Buffer time",
                           kind: .segmented([5, 10, 15, 20, 30]),
                           target: .eventMinutes(index: 0)),
            ],
            minBreakMinutes: minutes
        )
    }

    static let tooManyMeetings = ScheduleRecipe(
        id: "too-many-meetings",
        name: "Too Many Meetings",
        description: "Caps meetings at 4/day, moves extras to other days",
        category: "meetings",
        horizon: .week,
        weights: [.weekBalance: 2.0],
        speed: .balanced,
        conditions: [.meetingHeavy(threshold: 5)],
        params: [
            RecipeParam(id: "maxMeetings", label: "Max meetings/day",
                       kind: .segmented([2, 3, 4, 5, 6]),
                       target: .maxMeetings),
        ],
        maxMeetingsPerDay: 4
    )

    static func prepBeforeMeeting(minutes: Int = 30) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "prep-meeting",
            name: "Prep Before Meeting",
            description: "Creates a prep event right before the chosen meeting",
            category: "meetings",
            events: [
                EventSpec(title: "Prep", minutes: minutes,
                         priority: 0.85, energy: 0.4),
            ],
            weights: [.deadline: 5.0, .contextSwitch: 1.5],
            display: .confirmation,
            params: [
                RecipeParam(id: "eventId", label: "Which meeting?",
                           kind: .eventPicker, target: .placeholder("meetingId")),
                RecipeParam(id: "minutes", label: "Prep time",
                           kind: .segmented([15, 30, 45, 60]),
                           target: .eventMinutes(index: 0)),
            ]
        )
    }

    // ═══════════════════════════════════════════════════════
    // ENERGY & BALANCE
    // ═══════════════════════════════════════════════════════

    static let lowEnergyDay = ScheduleRecipe(
        id: "low-energy",
        name: "Low Energy Day",
        description: "Adds longer breaks, reduces back-to-back tasks",
        category: "energy",
        weights: [.breakPlacement: 2.5, .buffer: 1.5, .focusBlock: 0.5],
        params: [
            RecipeParam(id: "minBreak", label: "Min break between tasks",
                       kind: .segmented([10, 15, 20, 30, 45]),
                       target: .minBreak),
        ],
        minBreakMinutes: 20
    )

    static let morningPerson = ScheduleRecipe(
        id: "morning-person",
        name: "Morning Person",
        description: "Moves heavy tasks to the morning, light ones to PM",
        category: "energy",
        weights: [.energyCurve: 2.0],
        eventRules: [
            EventRule(match: .highEnergy, action: .setPreferredPeriod(.morning)),
        ],
        params: [
            RecipeParam(id: "peakHour", label: "Peak energy hour",
                       kind: .hourPicker(7...12),
                       target: .peakEnergy),
        ],
        peakEnergyHour: 9
    )

    static let postLunchDip = ScheduleRecipe(
        id: "post-lunch-dip",
        name: "Post-Lunch Dip",
        description: "Moves demanding tasks before lunch, easy ones after",
        category: "energy",
        weights: [.energyCurve: 2.0],
        eventRules: [
            EventRule(match: .highEnergy, action: .setPreferredPeriod(.morning)),
        ],
        params: [
            RecipeParam(id: "peakHour", label: "Peak energy hour",
                       kind: .hourPicker(8...13),
                       target: .peakEnergy),
        ],
        peakEnergyHour: 10
    )

    static let windDownLastHour = ScheduleRecipe(
        id: "wind-down",
        name: "Wind Down",
        description: "Keeps only light tasks in the last working hour",
        category: "energy",
        weights: [.energyCurve: 2.0],
        dayStructure: [
            TimeBlock(period: .evening, allowedTypes: [.tasks, .breaks]),
        ]
    )

    static let lightenTomorrow = ScheduleRecipe(
        id: "lighten-tomorrow",
        name: "Lighten Tomorrow",
        description: "Caps meetings at 3 and adds breaks for tomorrow",
        category: "energy",
        horizon: .tomorrow,
        weights: [.breakPlacement: 2.0],
        params: [
            RecipeParam(id: "maxMeetings", label: "Max meetings/day",
                       kind: .segmented([1, 2, 3, 4, 5]),
                       target: .maxMeetings),
            RecipeParam(id: "horizon", label: "Apply to",
                       kind: .horizonPicker, target: .horizon),
        ],
        maxMeetingsPerDay: 3
    )

    static let balanceWeek = ScheduleRecipe(
        id: "balance-week",
        name: "Balance Week",
        description: "Redistributes tasks so no day is overloaded",
        category: "energy",
        horizon: .week,
        weights: [.weekBalance: 2.0],
        speed: .balanced,
        params: [
            RecipeParam(id: "events", label: "Which tasks to balance?",
                       kind: .eventMultiPicker, target: .selectedEventIds),
            RecipeParam(id: "horizon", label: "Time range",
                       kind: .horizonPicker, target: .horizon),
        ]
    )

    static let focusMeetingSplit = ScheduleRecipe(
        id: "focus-meeting-split",
        name: "Focus / Meeting Days",
        description: "Moves meetings to Tue/Thu, focus work to Mon/Wed/Fri",
        category: "energy",
        horizon: .week,
        weights: [.contextSwitch: 5.0, .weekBalance: 0.5],
        speed: .thorough,
        eventRules: [
            EventRule(match: .meetings, action: .restrictToDays([3, 5])),
            EventRule(match: .focusBlocks, action: .restrictToDays([2, 4, 6])),
        ]
    )

    static let freeFriday = ScheduleRecipe(
        id: "free-friday",
        name: "Free Friday",
        description: "Moves all tasks to Mon–Thu, clears Friday",
        category: "energy",
        horizon: .week,
        weights: [.weekBalance: 2.0],
        speed: .balanced,
        eventRules: [
            EventRule(match: .all, action: .restrictToDays([2, 3, 4, 5])),
        ]
    )

    // ═══════════════════════════════════════════════════════
    // HABITS & ROUTINE
    // ═══════════════════════════════════════════════════════

    static func morningRoutine(minutes: Int = 30) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "morning-routine",
            name: "Morning Routine",
            description: "Finds morning slots and creates a daily routine event for the week",
            category: "habits",
            events: [
                EventSpec(title: "Morning Routine", minutes: minutes, count: 5,
                         priority: 0.85, energy: 0.2,
                         period: .morning, focus: true),
            ],
            findSlotOnly: true,
            horizon: .week,
            weights: [.focusBlock: 1.5],
            speed: .balanced,
            params: [
                RecipeParam(id: "minutes", label: "Duration",
                           kind: .segmented([15, 30, 45, 60]),
                           target: .eventMinutes(index: 0)),
            ]
        )
    }

    static func eveningWrapUp(minutes: Int = 15) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "evening-wrap-up",
            name: "Evening Wrap-up",
            description: "Finds evening slots and creates a daily wrap-up event for the week",
            category: "habits",
            events: [
                EventSpec(title: "Day Wrap-up", minutes: minutes, count: 5,
                         priority: 0.7, energy: 0.2, period: .evening),
            ],
            findSlotOnly: true,
            horizon: .week,
            weights: [.energyCurve: 1.5],
            speed: .balanced
        )
    }

    static func regularLearning(topic: String = "Learning", hoursPerWeek: Int = 5, sessionMinutes: Int = 60) -> ScheduleRecipe {
        let sessionCount = max(1, hoursPerWeek * 60 / sessionMinutes)
        return ScheduleRecipe(
            id: "regular-learning",
            name: "Regular Learning",
            description: "Finds free slots and creates learning sessions across the week",
            category: "habits",
            events: [
                EventSpec(title: topic, minutes: sessionMinutes, count: sessionCount,
                         priority: 0.7, energy: 0.7, context: topic, focus: true),
            ],
            findSlotOnly: true,
            horizon: .week,
            weights: [.weekBalance: 1.5, .focusBlock: 1.5],
            speed: .balanced,
            params: [
                RecipeParam(id: "title", label: "What to learn?",
                           kind: .text, target: .eventTitle(index: 0)),
                RecipeParam(id: "minutes", label: "Session length",
                           kind: .segmented([30, 60, 90, 120]),
                           target: .eventMinutes(index: 0)),
            ]
        )
    }

    static let movementReminders = ScheduleRecipe(
        id: "movement-reminders",
        name: "Movement Breaks",
        description: "Finds gaps between tasks and creates 4 movement break events",
        category: "habits",
        events: [
            EventSpec(title: "Movement Break", minutes: 10, count: 4,
                     priority: 0.6, energy: 0.0),
        ],
        findSlotOnly: true,
        weights: [.breakPlacement: 2.0]
    )

    // ═══════════════════════════════════════════════════════
    // PROJECTS
    // ═══════════════════════════════════════════════════════

    static let groupByProject = ScheduleRecipe(
        id: "group-by-project",
        name: "Group by Project",
        description: "Groups tasks by project to reduce context switches",
        category: "projects",
        weights: [.contextSwitch: 4.0],
        speed: .balanced,
        params: [
            RecipeParam(id: "events", label: "Which tasks to group?",
                       kind: .eventMultiPicker, target: .selectedEventIds),
        ]
    )

    static func prioritizeProject(name: String = "") -> ScheduleRecipe {
        ScheduleRecipe(
            id: "prioritize-project",
            name: "Prioritize Project",
            description: "Moves project tasks to morning peak-energy slots",
            category: "projects",
            horizon: .week,
            weights: [.energyCurve: 1.5],
            speed: .balanced,
            eventRules: [
                EventRule(match: .context("$project"), action: .setPriority(0.95)),
                EventRule(match: .context("$project"), action: .setPreferredPeriod(.morning)),
            ],
            params: [
                RecipeParam(id: "project", label: "Which project?",
                           kind: .text, target: .placeholder("project")),
            ]
        )
    }

    static func splitLargeTask(sessions: Int = 4, sessionMinutes: Int = 120) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "split-task",
            name: "Split Large Task",
            description: "Splits a task into sessions and spreads across the week",
            category: "projects",
            events: [
                EventSpec(title: "Session", minutes: sessionMinutes, count: sessions,
                         priority: 0.8, energy: 0.7, focus: true,
                         creation: .splitEvent("$eventId")),
            ],
            horizon: .week,
            weights: [.weekBalance: 1.5, .contextSwitch: 1.5],
            speed: .balanced,
            postActions: [.removeOriginalEvent("$eventId"), .showScenarios],
            params: [
                RecipeParam(id: "eventId", label: "Which task?",
                           kind: .eventPicker, target: .placeholder("eventId")),
                RecipeParam(id: "count", label: "Sessions",
                           kind: .segmented([2, 3, 4, 6, 8]),
                           target: .eventCount(index: 0)),
            ]
        )
    }

    static let alternateTaskTypes = ScheduleRecipe(
        id: "alternate-types",
        name: "Alternate Task Types",
        description: "Alternates task types so similar work isn't back-to-back",
        category: "projects",
        weights: [.contextSwitch: 0.1],
        params: [
            RecipeParam(id: "events", label: "Which tasks to mix?",
                       kind: .eventMultiPicker, target: .selectedEventIds),
        ]
    )

    static let carryOverUnfinished = ScheduleRecipe(
        id: "carry-over",
        name: "Carry Over Unfinished",
        description: "Finds unfinished tasks and schedules them this week",
        category: "projects",
        events: [
            EventSpec(creation: .fromUnfinished),
        ],
        horizon: .week,
        speed: .balanced,
        conditions: [.dayOfWeek(2)]
    )

    // ═══════════════════════════════════════════════════════
    // DAY ADJUSTMENTS
    // ═══════════════════════════════════════════════════════

    static func shortDay(endHour: Int = 15) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "short-day",
            name: "Short Day",
            description: "Compresses tasks into a shorter working day",
            category: "adapt",
            display: .confirmation,
            params: [
                RecipeParam(id: "end", label: "Work until",
                           kind: .hourPicker(13...18),
                           target: .workingHoursEnd),
            ],
            workingHours: HourRange(start: 9, end: endHour)
        )
    }

    static func lateStart(startHour: Int = 11) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "late-start",
            name: "Late Start",
            description: "Shifts tasks later, frees up the morning",
            category: "adapt",
            display: .confirmation,
            params: [
                RecipeParam(id: "start", label: "Start at",
                           kind: .hourPicker(8...13),
                           target: .workingHoursStart),
            ],
            workingHours: HourRange(start: startHour, end: 18)
        )
    }

    static let workFromHome = ScheduleRecipe(
        id: "wfh",
        name: "Work from Home",
        description: "Extends working hours to 8–19, favors longer focus blocks",
        category: "adapt",
        weights: [.focusBlock: 1.5],
        workingHours: HourRange(start: 8, end: 19)
    )

    static let halfDayBlocked = ScheduleRecipe(
        id: "half-day-blocked",
        name: "Half Day Blocked",
        description: "Squeezes tasks into the available half of the day",
        category: "adapt"
    )

    static let optimizeMorningOnly = ScheduleRecipe(
        id: "morning-only",
        name: "Morning Only",
        description: "Rearranges tasks within the 9–13 window only",
        category: "adapt",
        workingHours: HourRange(start: 9, end: 13)
    )

    static func noMeetingsBefore(hour: Int = 10) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "no-meetings-before",
            name: "No Meetings Before \(hour)",
            description: "Moves meetings to the afternoon, protects mornings",
            category: "adapt",
            horizon: .week,
            speed: .balanced,
            eventRules: [
                EventRule(match: .meetings, action: .setPreferredPeriod(.afternoon)),
            ],
            params: [
                RecipeParam(id: "hour", label: "No meetings before",
                           kind: .hourPicker(8...12),
                           target: .peakEnergy),
            ]
        )
    }

    // ═══════════════════════════════════════════════════════
    // ADVANCED
    // ═══════════════════════════════════════════════════════

    static let showOptions = ScheduleRecipe(
        id: "show-options",
        name: "Show 3 Options",
        description: "Generates 3 different schedule options to compare",
        category: "work-styles",
        speed: .balanced,
        params: [
            RecipeParam(id: "events", label: "Which tasks to optimize?",
                       kind: .eventMultiPicker, target: .selectedEventIds),
        ],
        diversityThreshold: 0.25
    )

    static let likeYesterday = ScheduleRecipe(
        id: "like-yesterday",
        name: "Like Yesterday",
        description: "Rearranges using patterns learned from your past choices",
        category: "work-styles",
        weights: [.useLearned: 1.0]
    )

    static let makerSchedule = ScheduleRecipe(
        id: "maker-schedule",
        name: "Maker Schedule",
        description: "Moves focus work to mornings, meetings to afternoons",
        category: "work-styles",
        weights: [.focusBlock: 2.0, .contextSwitch: 2.0],
        eventRules: [
            EventRule(match: .meetings, action: .setPreferredPeriod(.afternoon)),
            EventRule(match: .focusBlocks, action: .setPreferredPeriod(.morning)),
        ],
        dayStructure: [
            TimeBlock(period: .morning, allowedTypes: [.focus]),
            TimeBlock(period: .afternoon, allowedTypes: [.meetings, .tasks]),
        ]
    )

    static let managerSchedule = ScheduleRecipe(
        id: "manager-schedule",
        name: "Manager Schedule",
        description: "Moves meetings to mornings, admin and focus to afternoons",
        category: "work-styles",
        weights: [.contextSwitch: 2.0],
        eventRules: [
            EventRule(match: .meetings, action: .setPreferredPeriod(.morning)),
        ],
        dayStructure: [
            TimeBlock(period: .morning, allowedTypes: [.meetings]),
            TimeBlock(period: .afternoon, allowedTypes: [.tasks, .focus]),
        ]
    )

    // ═══════════════════════════════════════════════════════
    // WORKOUTS & ACTIVITIES
    // ═══════════════════════════════════════════════════════

    static func circuitTraining(rounds: Int = 3, exerciseMinutes: Int = 3, restMinutes: Int = 1, exercises: Int = 4) -> ScheduleRecipe {
        let roundMinutes = exerciseMinutes * exercises + restMinutes * (exercises - 1)
        let roundBreakMinutes = 3

        var events: [EventSpec] = []

        // Build segments for round detail
        var segments: [EventSegment] = []
        let exerciseNames = ["Squats", "Push-ups", "Plank", "Lunges", "Burpees", "Mountain Climbers"]
        for i in 0..<exercises {
            let name = i < exerciseNames.count ? exerciseNames[i] : "Exercise \(i + 1)"
            segments.append(EventSegment(title: name, minutes: exerciseMinutes, type: .work))
            if i < exercises - 1 {
                segments.append(EventSegment(title: "Rest", minutes: restMinutes, type: .rest))
            }
        }

        for round in 0..<rounds {
            events.append(EventSpec(
                title: "Round \(round + 1)",
                minutes: roundMinutes,
                energy: 0.9,
                context: "workout",
                chainGap: round == 0 ? nil : 0,
                segments: round == 0 ? segments : nil // segments on first round only
            ))
            if round < rounds - 1 {
                events.append(EventSpec(
                    title: "Round Break",
                    minutes: roundBreakMinutes,
                    energy: 0.0,
                    context: "workout",
                    chainGap: 0
                ))
            }
        }

        return ScheduleRecipe(
            id: "circuit-training",
            name: "Circuit Training",
            description: "Finds a free slot and creates a \(rounds)×\(exercises) circuit workout",
            category: "workouts",
            events: events,
            includeExistingEvents: false,
            weights: [.energyCurve: 2.0],
            params: [
                RecipeParam(id: "rounds", label: "Rounds",
                           kind: .segmented([2, 3, 4, 5]),
                           target: .eventCount(index: 0)),
            ]
        )
    }

    static func yogaSession(minutes: Int = 60) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "yoga-session",
            name: "Yoga Session",
            description: "Finds a free slot and creates a yoga session event",
            category: "workouts",
            events: [
                EventSpec(
                    title: "Yoga",
                    minutes: minutes,
                    energy: 0.4,
                    context: "wellness",
                    period: .morning,
                    segments: [
                        EventSegment(title: "Warm-up", minutes: max(5, minutes / 6), type: .transition),
                        EventSegment(title: "Main Practice", minutes: max(10, minutes * 2 / 3), type: .work),
                        EventSegment(title: "Savasana", minutes: max(5, minutes / 6), type: .rest),
                    ]
                ),
            ],
            includeExistingEvents: false,
            weights: [.energyCurve: 1.5],
            params: [
                RecipeParam(id: "minutes", label: "Duration",
                           kind: .segmented([30, 45, 60, 90]),
                           target: .eventMinutes(index: 0)),
            ]
        )
    }

    static func intervalTraining(intervals: Int = 6, workMinutes: Int = 4, restMinutes: Int = 2) -> ScheduleRecipe {
        let totalMinutes = (workMinutes + restMinutes) * intervals + 5 + 5 // warm-up + cool-down

        var segments: [EventSegment] = [
            EventSegment(title: "Warm-up", minutes: 5, type: .transition),
        ]
        for i in 0..<intervals {
            segments.append(EventSegment(title: "Interval \(i + 1)", minutes: workMinutes, type: .work))
            if i < intervals - 1 {
                segments.append(EventSegment(title: "Recovery", minutes: restMinutes, type: .rest))
            }
        }
        segments.append(EventSegment(title: "Cool-down", minutes: 5, type: .transition))

        return ScheduleRecipe(
            id: "interval-training",
            name: "Interval Training",
            description: "Finds a free slot and creates a \(intervals)-interval HIIT event",
            category: "workouts",
            events: [
                EventSpec(
                    title: "Interval Training",
                    minutes: totalMinutes,
                    energy: 0.95,
                    context: "workout",
                    period: .morning,
                    segments: segments
                ),
            ],
            includeExistingEvents: false,
            weights: [.energyCurve: 2.0],
            params: [
                RecipeParam(id: "intervals", label: "Intervals",
                           kind: .segmented([4, 6, 8, 10]),
                           target: .eventCount(index: 0)),
            ]
        )
    }

    // ═══════════════════════════════════════════════════════
    // REACTIONS (auto-triggered)
    // ═══════════════════════════════════════════════════════

    static let onEventDeleted = ScheduleRecipe(
        id: "on-event-deleted",
        name: "Smart Reschedule",
        description: "Adjust schedule after event removal",
        stability: .conservative,
        trigger: .eventDeleted,
        display: .inline,
        postActions: [.suggestInGap],
        learnable: false
    )

    static let onEventMoved = ScheduleRecipe(
        id: "on-event-moved",
        name: "Readjust Schedule",
        description: "Shift remaining events",
        stability: .conservative,
        trigger: .eventMoved,
        display: .confirmation,
        postActions: [.undoable],
        learnable: false
    )

    static let onEventCreated = ScheduleRecipe(
        id: "on-event-created",
        name: "Fit New Event",
        description: "Adjust schedule for new event",
        stability: .conservative,
        trigger: .eventCreated,
        display: .toast,
        learnable: false
    )
}
