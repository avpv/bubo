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

    /// Screen model: timeline/filter state, day-nav focus, the shared
    /// minute tick, sync-lifecycle flags, permission snapshots, the
    /// popover-owned session state (toasts, scroll position, quick
    /// capture, day-rollover timer, measured optimizer-bar bottom), and
    /// all pure derived computation (UI_REFACTORING.md stage 3).
    @State var screen: MenuBarScreenModel

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
            settings: settings,
            backlogCoordinator: coordinator
        ))
    }

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
                value: screen.navigation
            )

            commandPaletteOverlay()

            ToastOverlay(toastState: screen.toastState)

            keyboardShortcutsLayer()
        }
        .skinTinted(activeSkin)
        .skinTypography(activeSkin)
        .environment(\.activeSkin, activeSkin)
        .environment(\.backlogCoordinator, backlogCoordinator)
        // PRINCIPLES §9 — event-row verbs travel through the environment;
        // one installation point covers every row in the timeline.
        .environment(\.eventRowActions, eventRowActions)
        .environment(\.navigateHome, { screen.navigation = .list })
        .coordinateSpace(name: menuBarRootCoordinateSpace)
        .onPreferenceChange(OptimizerBottomKey.self) { screen.optimizerBottomY = $0 }
        .onReceive(everyMinuteTimer) { tick in
            // Drives the «happening now» highlight on EventRowView. One
            // shared tick across every row keeps the row a pure View
            // (no per-row timers).
            screen.nowTick = tick
        }
        .frame(width: DS.Popover.width, height: screen.navigation.isTimer ? DS.Popover.timerHeight : DS.Popover.height)
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
