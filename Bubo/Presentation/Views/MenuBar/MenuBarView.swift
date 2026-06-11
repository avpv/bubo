import SwiftUI
import BuboDomain

struct MenuBarView: View {
    @Environment(\.activeSkin) var skin
    var settings: ReminderSettings
    var reminderService: ReminderService
    var networkMonitor: NetworkMonitor
    var optimizerService: OptimizerService
    var agentService: AgentService
    var remindersSyncService: RemindersSyncService

    @Environment(\.openSettings) var openSettings

    @State var navigation: MenuBarNavigation = .list
    @State var hasStartedSync = false
    /// Day-rollover timer for `AutoDeferService` — fires shortly past
    /// midnight so the «left popover open overnight» case picks up the
    /// new day's deferral pass without requiring the user to reopen
    /// the popover. Stored as state so the lifecycle tracks the view's
    /// — created in `onAppear`, invalidated in `onDisappear`. Without
    /// this, AutoDefer only ran on popover-open, which missed users
    /// who keep the menu bar pinned overnight.
    @State var dayRolloverTimer: Timer? = nil
    /// Becomes true 3\u{00A0}s after the first popover open, regardless of
    /// whether the EventKit sync has produced events yet. Used to escalate
    /// the «Syncing calendars…» panel into «Sync taking long» so the user
    /// has a path to action when the system actually is stuck.
    @State var initialSyncTimeoutFired = false
    /// Becomes true the first time `reminderService` reports a non-empty
    /// event list, marking the sync as «produced something». Used to drop
    /// out of the syncing panel once data lands, even before the 3\u{00A0}s
    /// timeout. Once latched, never resets — the panel is one-shot per
    /// app launch, not a recurring spinner on every empty state.
    @State var initialSyncDataArrived = false
    @State var toastState = ToastState()
    @State var scrollPositionID: String?

    /// Timeline/filter state + pure derived computation for the popover —
    /// colour & free-slot filters, day-nav focus, horizon extension, the
    /// shared minute tick, timeline shaping, and the header strings.
    /// (UI_REFACTORING.md stage 3, first slice.)
    @State var screen: MenuBarScreenModel

    /// Vertical scroll offset (in points, negative as the user scrolls
    /// down) of the event list. Consumed by `AppBackgroundLayer` to
    /// drive a small parallax on the wallpaper — the background drifts
    /// at ~15% of foreground velocity, giving a depth cue that the
    /// foreground content is closer to the eye than the wallpaper.
    /// Reset to zero when leaving the list view or when Reduce Motion
    /// is on, so no extra paint cost on accessibility paths.
    @State var listScrollY: CGFloat = 0

    /// Shared state for backlog drag-to-schedule + ghost-preview. Owned here
    /// because both the drag source (BacklogView) and the drop targets
    /// (FreeSlotRow instances scattered across the day list) need it, and the
    /// ghost block on the timeline is rendered by this view.
    @State var backlogCoordinator: BacklogInteractionCoordinator

    /// Shared minute timer — feeds `screen.nowTick` so every consumer
    /// (row highlight, header strings) reads one Date instead of owning
    /// its own timer.
    private let everyMinuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(
        settings: ReminderSettings,
        reminderService: ReminderService,
        networkMonitor: NetworkMonitor,
        optimizerService: OptimizerService,
        agentService: AgentService,
        remindersSyncService: RemindersSyncService
    ) {
        self.settings = settings
        self.reminderService = reminderService
        self.networkMonitor = networkMonitor
        self.optimizerService = optimizerService
        self.agentService = agentService
        self.remindersSyncService = remindersSyncService

        // The screen model reads the ghost slot off the coordinator, so
        // both are created here and share one instance.
        let coordinator = BacklogInteractionCoordinator()
        _backlogCoordinator = State(initialValue: coordinator)
        _screen = State(initialValue: MenuBarScreenModel(
            reminderService: reminderService,
            optimizerService: optimizerService,
            backlogCoordinator: coordinator
        ))
    }

    /// Drives the quick-capture popover anchored on the SmartActionsBar's
    /// Backlog chip. Lifted to MenuBarView so the global ⇧⌘N shortcut
    /// can flip it from outside (chip click flips its own internal
    /// state via the same binding).
    @State var showingQuickCapture: Bool = false

    // Command palette — the single entry point for all optimize flows.
    @State var paletteContext: MenuBarPaletteContext? = nil
    @State var dismissedBannerIds: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: "BuboDismissedBannerIds") ?? []
        return Set(stored)
    }()

    /// Cached EventKit permission snapshots driving access-aware gating.
    /// EventKit exposes auth status only as a non-observable static call, so
    /// the view body cannot reactively re-evaluate it. Mirroring it into
    /// `@State` (refreshed on the services' `authorizationDidChange`
    /// notifications and on appear) makes the banner disappear immediately
    /// when the user grants access via the Settings pane.
    @State var calendarHasAccess: Bool = AppleCalendarService.hasAccess
    @State var remindersHasAccess: Bool = AppleRemindersService.hasAccess

    /// Measured bottom edge (in the root coordinate space) of the QuickActions
    /// "Optimize" bar. We anchor the command palette overlay just below this
    /// point so the optimizer trigger stays visible while the palette is open.
    @State var optimizerBottomY: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // `Navigation` and `PaletteContext` extracted to file scope in
    // `Views/MenuBarNavigation.swift` and `Views/MenuBarPaletteContext.swift`
    // — see `MenuBarNavigation` and `MenuBarPaletteContext`.


    var activeSkin: SkinDefinition { settings.selectedSkin }

    var body: some View {
        ZStack {
            AppBackgroundLayer(
                skin: activeSkin,
                wallpaper: settings.selectedWallpaper,
                customPhotoPath: settings.customBackgroundPhotoPath,
                customPhotoOpacity: settings.customBackgroundPhotoOpacity,
                customPhotoBlur: settings.customBackgroundPhotoBlur,
                parallaxY: parallaxOffset
            )

            Group {
                navigationDestination()
            }
            .animation(
                reduceMotion ? DS.Animation.quick : DS.Animation.smoothSpring,
                value: navigation
            )

            commandPaletteOverlay()

            ToastOverlay(toastState: toastState)

            keyboardShortcutsLayer()
        }
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)
        .environment(\.activeSkin, activeSkin)
        .environment(\.backlogCoordinator, backlogCoordinator)
        .environment(\.navigateHome, { navigation = .list })
        .coordinateSpace(name: menuBarRootCoordinateSpace)
        .onPreferenceChange(OptimizerBottomKey.self) { optimizerBottomY = $0 }
        .onReceive(everyMinuteTimer) { tick in
            // Drives the «happening now» highlight on EventRowView. One
            // shared tick across every row keeps the row a pure View
            // (no per-row timers).
            screen.nowTick = tick
        }
        .frame(width: DS.Popover.width, height: navigation.isTimer ? DS.Popover.timerHeight : DS.Popover.height)
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: reminderService.allEvents.isEmpty) { _, isEmpty in
            handleEventListIsEmptyChange(isEmpty)
        }
        .onChange(of: optimizerService.backlogService?.tasks.count ?? 0) { _, _ in
            handleBacklogTaskCountChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppleCalendarService.authorizationDidChange), perform: handleCalendarAuthChange)
        .onReceive(NotificationCenter.default.publisher(for: AppleRemindersService.authorizationDidChange), perform: handleRemindersAuthChange)
        .onReceive(NotificationCenter.default.publisher(for: RemindersSyncService.didImportTasks), perform: handleImportedTasks)
        .onReceive(NotificationCenter.default.publisher(for: .didCaptureBacklogTask), perform: handleCapturedBacklogTask)
        .onReceive(NotificationCenter.default.publisher(for: .didCaptureBacklogTaskWithDetails), perform: handleCapturedBacklogTaskWithDetails)
        .onReceive(NotificationCenter.default.publisher(for: BacklogService.taskCompleted), perform: handleTaskCompletedNotification)
    }


    // MARK: - Helpers

    // Timeline shaping, day-nav focus, and the computed header strings
    // live on `MenuBarScreenModel` (`screen`) — see
    // `Views/MenuBar/MenuBarScreenModel.swift`.

    // Main content composition (`mainContent`, `eventList`,
    // `syncingState`, `parallaxOffset`, `dayNavCluster`,
    // `navigateToDay`) lives in `MenuBarView+MainContent.swift`.

    // Day-group section pieces (`dayGroupHeader`, `dayGroupSection`,
    // `freeSlotRow`, `collapsedEventsHeader`) live in
    // `MenuBarView+DayGroup.swift`.

    // Auto-Defer and End-of-Day Banner methods live in
    // `MenuBarView+AutoDefer.swift` — the once-a-day deferral pass and
    // the J10 wind-down banner are a single lifecycle concern.

}

// Sub-components and preference keys extracted to dedicated files:
//   - `Views/Components/OpenSettingsButton.swift`
//   - `Views/Components/Banner/PermissionBannerRow.swift`
//   - `Views/MenuBarPreferenceKeys.swift`
