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
        let icon: String
        let recipes: [ScheduleRecipe]
    }

    static let allCategories: [Category] = [
        Category(id: "focus", name: "Focus & Deep Work", icon: "brain.head.profile", recipes: [
            .needFocus(), .pomodoroSession(), .structuredDeepWork(),
            .deepWorkDay(), .maxProductivity,
        ]),
        Category(id: "planning", name: "Planning", icon: "calendar", recipes: [
            .organizeDay, .planWeek, .fullRebuild,
        ]),
        Category(id: "deadlines", name: "Deadlines", icon: "flame", recipes: [
            .deadlineMode, .deadlineCrunch, .multipleDeadlines,
        ]),
        Category(id: "meetings", name: "Meetings", icon: "person.2", recipes: [
            .batchMeetings, .bufferBetweenMeetings(),
            .tooManyMeetings, .prepBeforeMeeting(),
        ]),
        Category(id: "energy", name: "Energy & Balance", icon: "bolt.heart", recipes: [
            .lowEnergyDay, .morningPerson, .postLunchDip,
            .windDownLastHour, .lightenTomorrow,
            .balanceWeek, .focusMeetingSplit, .freeFriday,
        ]),
        Category(id: "habits", name: "Habits & Routine", icon: "repeat", recipes: [
            .morningRoutine(), .eveningWrapUp(), .regularLearning(),
            .movementReminders,
        ]),
        Category(id: "projects", name: "Projects", icon: "folder", recipes: [
            .groupByProject, .prioritizeProject(),
            .splitLargeTask(), .alternateTaskTypes,
            .carryOverUnfinished,
        ]),
        Category(id: "adapt", name: "Day Adjustments", icon: "clock.arrow.2.circlepath", recipes: [
            .shortDay(), .lateStart(), .workFromHome,
            .halfDayBlocked, .optimizeMorningOnly,
            .noMeetingsBefore(),
        ]),
        Category(id: "workouts", name: "Workouts & Activities", icon: "figure.run", recipes: [
            .circuitTraining(), .yogaSession(), .intervalTraining(),
        ]),
        Category(id: "advanced", name: "Advanced", icon: "slider.horizontal.3", recipes: [
            .showOptions, .likeYesterday, .makerSchedule, .managerSchedule,
        ]),
    ]

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
            icon: "brain.head.profile",
            description: "Find uninterrupted focus time",
            category: "focus",
            events: [
                EventSpec(title: "Focus Time", minutes: minutes,
                         priority: 0.9, energy: 0.7,
                         period: .morning, focus: true),
            ],
            weights: [.focusBlock: 2.0],
            params: [
                RecipeParam(id: "minutes", label: "How long?",
                           kind: .segmented([30, 60, 90, 120, 180]),
                           target: .eventMinutes(index: 0)),
            ]
        )
    }

    static func pomodoroSession(preset: PomodoroPreset = .classic) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "pomodoro",
            name: "Pomodoro Session",
            icon: "timer",
            description: "Find best slot for pomodoro",
            category: "focus",
            events: [
                EventSpec(title: "Pomodoro Session", minutes: preset.totalMinutes,
                         priority: 0.7, energy: 0.8,
                         period: .morning, focus: true, pomodoro: preset),
            ],
            weights: [.pomodoroFit: 1.5, .energyCurve: 1.5]
        )
    }

    static func structuredDeepWork(minutes: Int = 130) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "structured-deep-work",
            name: "Structured Deep Work",
            icon: "brain.head.profile",
            description: "Focus block with pomodoro structure inside",
            category: "focus",
            events: [
                EventSpec(title: "Deep Work", minutes: minutes,
                         priority: 0.9, energy: 0.8,
                         period: .morning, focus: true, pomodoro: .classic),
            ],
            weights: [.focusBlock: 2.5, .pomodoroFit: 2.0],
            params: [
                RecipeParam(id: "minutes", label: "Total time",
                           kind: .segmented([90, 120, 130, 180]),
                           target: .eventMinutes(index: 0)),
            ]
        )
    }

    static func deepWorkDay(count: Int = 2, minutes: Int = 120) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "deep-work-day",
            name: "Deep Work Day",
            icon: "brain",
            description: "Focus blocks as anchors, tasks arranged around them",
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
        icon: "bolt",
        description: "Maximum deep work, minimum interruptions",
        category: "focus",
        events: [
            EventSpec(title: "Deep Work", minutes: 120, count: 3,
                     priority: 0.95, energy: 0.7, focus: true),
        ],
        weights: [.focusBlock: 3.0, .contextSwitch: 2.0, .energyCurve: 2.0],
        maxMeetingsPerDay: 2
    )

    // ═══════════════════════════════════════════════════════
    // PLANNING
    // ═══════════════════════════════════════════════════════

    static let organizeDay = ScheduleRecipe(
        id: "organize-day",
        name: "Organize Day",
        icon: "calendar.day.timeline.left",
        description: "Rearrange today's tasks for best flow",
        category: "planning",
        weights: [.energyCurve: 1.5, .contextSwitch: 1.2]
    )

    static let planWeek = ScheduleRecipe(
        id: "plan-week",
        name: "Plan Week",
        icon: "calendar",
        description: "Balance workload across the week",
        category: "planning",
        horizon: .week,
        weights: [.weekBalance: 1.5, .energyCurve: 1.5],
        speed: .balanced
    )

    static let fullRebuild = ScheduleRecipe(
        id: "full-rebuild",
        name: "Full Rebuild",
        icon: "arrow.triangle.2.circlepath",
        description: "Optimize everything from scratch",
        category: "planning",
        horizon: .week,
        stability: .full,
        speed: .thorough
    )

    // ═══════════════════════════════════════════════════════
    // DEADLINES
    // ═══════════════════════════════════════════════════════

    static let deadlineMode = ScheduleRecipe(
        id: "deadline-mode",
        name: "Deadline Mode",
        icon: "flame",
        description: "Clear path to your deadline",
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
        icon: "flame.fill",
        description: "Aggressive mode — minimize everything else",
        category: "deadlines",
        weights: [.deadline: 10.0, .breakPlacement: 0.3, .buffer: 0.1],
        speed: .balanced,
        eventRules: [
            EventRule(match: .withDeadline, action: .setPriority(1.0)),
            EventRule(match: .lowEnergy, action: .exclude),
        ],
        conditions: [.hasDeadlineWithin(days: 1)],
        minBreakMinutes: 5
    )

    static let multipleDeadlines = ScheduleRecipe(
        id: "multiple-deadlines",
        name: "Multiple Deadlines",
        icon: "flame.circle",
        description: "Spread deadline tasks across the week",
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
        icon: "person.2",
        description: "Group all meetings together",
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
            icon: "space",
            description: "\(minutes) min gap after each meeting",
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
        icon: "person.3",
        description: "Redistribute meetings across the week",
        category: "meetings",
        horizon: .week,
        weights: [.weekBalance: 2.0],
        speed: .balanced,
        conditions: [.meetingHeavy(threshold: 5)],
        maxMeetingsPerDay: 4
    )

    static func prepBeforeMeeting(minutes: Int = 30) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "prep-meeting",
            name: "Prep Before Meeting",
            icon: "note.text",
            description: "Add preparation time before a meeting",
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
        icon: "battery.25percent",
        description: "More breaks, lighter load",
        category: "energy",
        weights: [.breakPlacement: 2.5, .buffer: 1.5, .focusBlock: 0.5],
        minBreakMinutes: 20
    )

    static let morningPerson = ScheduleRecipe(
        id: "morning-person",
        name: "Morning Person",
        icon: "sunrise",
        description: "Hard tasks AM, light tasks PM",
        category: "energy",
        weights: [.energyCurve: 2.0],
        eventRules: [
            EventRule(match: .highEnergy, action: .setPreferredPeriod(.morning)),
        ],
        peakEnergyHour: 9
    )

    static let postLunchDip = ScheduleRecipe(
        id: "post-lunch-dip",
        name: "Post-Lunch Dip",
        icon: "moon.zzz",
        description: "Nothing hard after lunch",
        category: "energy",
        weights: [.energyCurve: 2.0],
        eventRules: [
            EventRule(match: .highEnergy, action: .setPreferredPeriod(.morning)),
        ],
        peakEnergyHour: 10
    )

    static let windDownLastHour = ScheduleRecipe(
        id: "wind-down",
        name: "Wind Down",
        icon: "sunset",
        description: "Only light tasks in the last hour",
        category: "energy",
        weights: [.energyCurve: 2.0],
        dayStructure: [
            TimeBlock(period: .evening, allowedTypes: [.tasks, .breaks]),
        ]
    )

    static let lightenTomorrow = ScheduleRecipe(
        id: "lighten-tomorrow",
        name: "Lighten Tomorrow",
        icon: "cloud",
        description: "Make tomorrow easier",
        category: "energy",
        horizon: .tomorrow,
        weights: [.breakPlacement: 2.0],
        maxMeetingsPerDay: 3
    )

    static let balanceWeek = ScheduleRecipe(
        id: "balance-week",
        name: "Balance Week",
        icon: "scale.3d",
        description: "Even out daily workload",
        category: "energy",
        horizon: .week,
        weights: [.weekBalance: 2.0],
        speed: .balanced
    )

    static let focusMeetingSplit = ScheduleRecipe(
        id: "focus-meeting-split",
        name: "Focus / Meeting Days",
        icon: "rectangle.split.2x1",
        description: "Separate focus days and meeting days",
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
        icon: "party.popper",
        description: "Compress work into Mon-Thu",
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
            icon: "sunrise.circle",
            description: "Protected morning ritual",
            category: "habits",
            events: [
                EventSpec(title: "Morning Routine", minutes: minutes, count: 5,
                         priority: 0.85, energy: 0.2,
                         period: .morning, focus: true),
            ],
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
            icon: "moon",
            description: "Daily review and planning",
            category: "habits",
            events: [
                EventSpec(title: "Day Wrap-up", minutes: minutes, count: 5,
                         priority: 0.7, energy: 0.2, period: .evening),
            ],
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
            icon: "book",
            description: "Dedicated time for learning",
            category: "habits",
            events: [
                EventSpec(title: topic, minutes: sessionMinutes, count: sessionCount,
                         priority: 0.7, energy: 0.7, context: topic, focus: true),
            ],
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
        icon: "figure.walk",
        description: "Regular breaks to move",
        category: "habits",
        events: [
            EventSpec(title: "Movement Break", minutes: 10, count: 4,
                     priority: 0.6, energy: 0.0),
        ],
        weights: [.breakPlacement: 2.0]
    )

    // ═══════════════════════════════════════════════════════
    // PROJECTS
    // ═══════════════════════════════════════════════════════

    static let groupByProject = ScheduleRecipe(
        id: "group-by-project",
        name: "Group by Project",
        icon: "folder",
        description: "Batch similar tasks together",
        category: "projects",
        weights: [.contextSwitch: 4.0],
        speed: .balanced
    )

    static func prioritizeProject(name: String = "") -> ScheduleRecipe {
        ScheduleRecipe(
            id: "prioritize-project",
            name: "Prioritize Project",
            icon: "star",
            description: "Give a project the best time slots",
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
            icon: "scissors",
            description: "Break a big task into sessions",
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
        icon: "arrow.left.arrow.right",
        description: "Mix different types of work for variety",
        category: "projects",
        weights: [.contextSwitch: 0.1]
    )

    static let carryOverUnfinished = ScheduleRecipe(
        id: "carry-over",
        name: "Carry Over Unfinished",
        icon: "arrow.uturn.forward",
        description: "Move last week's unfinished tasks",
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
            icon: "clock",
            description: "Leaving early today",
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
            icon: "alarm",
            description: "Starting late today",
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
        icon: "house",
        description: "Wider hours, longer focus blocks",
        category: "adapt",
        weights: [.focusBlock: 1.5],
        workingHours: HourRange(start: 8, end: 19)
    )

    static let halfDayBlocked = ScheduleRecipe(
        id: "half-day-blocked",
        name: "Half Day Blocked",
        icon: "rectangle.lefthalf.inset.filled",
        description: "Morning or afternoon is unavailable",
        category: "adapt"
    )

    static let optimizeMorningOnly = ScheduleRecipe(
        id: "morning-only",
        name: "Morning Only",
        icon: "sunrise",
        description: "Optimize only the morning",
        category: "adapt",
        workingHours: HourRange(start: 9, end: 13)
    )

    static func noMeetingsBefore(hour: Int = 10) -> ScheduleRecipe {
        ScheduleRecipe(
            id: "no-meetings-before",
            name: "No Meetings Before \(hour)",
            icon: "hand.raised",
            description: "Keep mornings meeting-free",
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
        icon: "square.stack.3d.up",
        description: "See diverse schedule alternatives",
        category: "advanced",
        speed: .balanced,
        diversityThreshold: 0.25
    )

    static let likeYesterday = ScheduleRecipe(
        id: "like-yesterday",
        name: "Like Yesterday",
        icon: "clock.arrow.circlepath",
        description: "Optimize using your learned preferences",
        category: "advanced",
        weights: [.useLearned: 1.0]
    )

    static let makerSchedule = ScheduleRecipe(
        id: "maker-schedule",
        name: "Maker Schedule",
        icon: "hammer",
        description: "Focus mornings, meetings afternoon",
        category: "advanced",
        dayStructure: [
            TimeBlock(period: .morning, allowedTypes: [.focus]),
            TimeBlock(period: .afternoon, allowedTypes: [.meetings, .tasks]),
        ],
        eventRules: [
            EventRule(match: .meetings, action: .setPreferredPeriod(.afternoon)),
            EventRule(match: .focusBlocks, action: .setPreferredPeriod(.morning)),
        ],
        weights: [.focusBlock: 2.0, .contextSwitch: 2.0]
    )

    static let managerSchedule = ScheduleRecipe(
        id: "manager-schedule",
        name: "Manager Schedule",
        icon: "briefcase",
        description: "Meetings morning, admin afternoon",
        category: "advanced",
        dayStructure: [
            TimeBlock(period: .morning, allowedTypes: [.meetings]),
            TimeBlock(period: .afternoon, allowedTypes: [.tasks, .focus]),
        ],
        eventRules: [
            EventRule(match: .meetings, action: .setPreferredPeriod(.morning)),
        ],
        weights: [.contextSwitch: 2.0]
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
                segments: round == 0 ? segments : nil, // segments on first round only
                chainGap: round == 0 ? nil : 0
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
            icon: "figure.run",
            description: "\(rounds) rounds × \(exercises) exercises",
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
            icon: "figure.yoga",
            description: "Warm-up, practice, savasana",
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
            icon: "figure.highintensity.intervaltraining",
            description: "\(intervals) intervals of \(workMinutes)min work / \(restMinutes)min rest",
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
        icon: "arrow.uturn.forward",
        description: "Adjust schedule after event removal",
        trigger: .eventDeleted,
        stability: .conservative,
        display: .inline,
        postActions: [.suggestInGap],
        learnable: false
    )

    static let onEventMoved = ScheduleRecipe(
        id: "on-event-moved",
        name: "Readjust Schedule",
        icon: "arrow.right.arrow.left",
        description: "Shift remaining events",
        trigger: .eventMoved,
        stability: .conservative,
        display: .confirmation,
        postActions: [.undoable],
        learnable: false
    )

    static let onEventCreated = ScheduleRecipe(
        id: "on-event-created",
        name: "Fit New Event",
        icon: "plus.circle",
        description: "Adjust schedule for new event",
        trigger: .eventCreated,
        stability: .conservative,
        display: .toast,
        learnable: false
    )
}
