import SwiftUI
import BuboDomain

// MARK: - Lifecycle
//
// `body`-companion pieces extracted to keep the body composition
// readable: the inline CommandPalette overlay, the two hidden
// keyboard-shortcut buttons (⌘K and ⇧⌘N), the `onAppear` /
// `onDisappear` blocks, and the per-notification handlers consumed
// by the `.onReceive` chain.

extension MenuBarView {

    // MARK: - CommandPalette Overlay

    @ViewBuilder
    func commandPaletteOverlay() -> some View {
        if let context = paletteContext {
            CommandPalette(
                optimizerService: optimizerService,
                reminderService: reminderService,
                agentService: agentService,
                seedEvent: context.seedEvent,
                seedTask: context.seedTask,
                seedSlotMinutes: context.seedSlotMinutes,
                seedSlotStart: context.seedSlotStart,
                seedSlotEnd: context.seedSlotEnd,
                seedPreset: context.seedRecipeId.flatMap { id in IntentPresets.all.first { $0.name == id } },
                onDismiss: {
                    withAnimation(DS.Animation.quick) { paletteContext = nil }
                },
                onApplied: { request, undo in
                    toastState.showSuccess(
                        "\(request.name ?? "Schedule") applied",
                        icon: "sparkles",
                        onUndo: undo
                    )
                },
                onOpenEvent: { event in
                    // Jump from the palette to the event detail. The
                    // palette dismiss happens in the row tap itself;
                    // we only flip navigation here. The detail view's
                    // own back button returns to the list.
                    withAnimation(DS.Animation.quick) {
                        paletteContext = nil
                        navigation = .detail(event)
                    }
                }
            )
            // The Backlog card publishes `OptimizerBottomKey`
            // (see its `.background(GeometryReader…)` modifier),
            // so `optimizerBottomY` reflects the card's bottom
            // edge. Fallback minimum (≈ WorldClock + filter bar
            // height) preserves a sensible position before the
            // first preference reading lands.
            .padding(.top, max(120, optimizerBottomY))
            .transition(.opacity)
            .zIndex(10)
        }
    }

    // MARK: - Hidden Keyboard Shortcuts

    @ViewBuilder
    func keyboardShortcutsLayer() -> some View {
        // ⌘K: toggle command palette. Lives outside the palette so it
        // can be triggered from any list state.
        Button("") {
            Haptics.tap()
            withAnimation(DS.Animation.quick) {
                if paletteContext == nil {
                    paletteContext = MenuBarPaletteContext()
                } else {
                    paletteContext = nil
                }
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)

        // ⇧⌘N: open the inline quick-capture popover anchored on the
        // SmartActionsBar's Backlog chip. Routes through `.list` first
        // so the bar is mounted when the popover tries to anchor.
        Button("") {
            Haptics.tap()
            if navigation != .list {
                navigation = .list
            }
            showingQuickCapture = true
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Appear / Disappear

    func handleAppear() {
        // Refresh permission snapshots every time the popover surfaces
        // — covers the case where the user granted access via System
        // Settings while we were closed. Cheap, idempotent, and
        // independent of the one-shot `hasStartedSync` guard below.
        refreshPermissionSnapshots()

        // Drain any ⇧↩ quick-capture prefill that was buffered while
        // this view wasn't in the tree. The bridge clears itself on
        // read, so a hot popover (notification path) and a cold
        // popover (this path) never both navigate.
        if let pending = QuickCaptureBridge.shared.take() {
            navigation = .newTask(prefillTitle: pending, prefillDuration: nil)
        }

        // AutoDefer runs once per calendar day. Calling on every
        // popover open is cheap (the service early-exits when
        // `lastRunDate` is today) and covers the «opened a fresh
        // morning» case automatically.
        runAutoDeferIfNeeded()
        scheduleDayRolloverTimerIfNeeded()

        guard !hasStartedSync else { return }
        hasStartedSync = true
        reminderService.updateSettings(settings)
        reminderService.startSync()
        remindersSyncService.updateSettings(settings)
        remindersSyncService.startSync()
        if let backlog = optimizerService.backlogService {
            optimizerService.setup(reminderService: reminderService, backlogService: backlog)
        } else {
            assertionFailure("BacklogService should be set in App.init")
        }
        Task {
            try? await Task.sleep(for: .seconds(5)) // wait for sync
            await optimizerService.runWeekMockSimulator(reminderService: reminderService)
        }
        // Escalate the «Syncing calendars…» panel to a long-running
        // hint after 3 s. If data arrives sooner, the panel disappears
        // via `initialSyncDataArrived` and the user never sees the
        // «taking long» copy.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            initialSyncTimeoutFired = true
        }
    }

    func handleDisappear() {
        // Tear down the day-rollover timer so we don't leak it when
        // the popover is dismissed. `onAppear` re-arms the timer on
        // the next open if the day hasn't yet rolled.
        dayRolloverTimer?.invalidate()
        dayRolloverTimer = nil
    }

    // MARK: - Notification Handlers

    /// Latch on the first non-empty event list — we treat that as
    /// «sync produced something», which is enough to drop the syncing
    /// panel. We don't unlatch when events go back to empty later
    /// (e.g. user filters everything out); one-shot per app launch.
    func handleEventListIsEmptyChange(_ isEmpty: Bool) {
        if !isEmpty { initialSyncDataArrived = true }
    }

    /// Backlog mutated → kick a fresh shadowProposal compute so the
    /// per-task ghost-slots / SmartActions delta hints stay current.
    /// `previewRequest` is fire-and-cancel: back-to-back edits collapse
    /// to one run on the latest state.
    func handleBacklogTaskCountChange() {
        optimizerService.previewRequest(.scheduleBacklog, reminderService: reminderService)
    }

    /// Trust the grant result if the service posted one — the static
    /// EKEventStore query can still return `.notDetermined` for a
    /// moment after the continuation resolves, leaving the banner
    /// stuck even though access was granted.
    func handleCalendarAuthChange(_ note: Notification) {
        if let granted = note.userInfo?["granted"] as? Bool {
            if calendarHasAccess != granted { calendarHasAccess = granted }
        } else {
            refreshPermissionSnapshots()
        }
    }

    func handleRemindersAuthChange(_ note: Notification) {
        if let granted = note.userInfo?["granted"] as? Bool {
            if remindersHasAccess != granted { remindersHasAccess = granted }
        } else {
            refreshPermissionSnapshots()
        }
    }

    func handleImportedTasks(_ notification: Notification) {
        guard let count = notification.object as? Int, count > 0 else { return }
        let noun = count == 1 ? "task" : "tasks"
        toastState.showInfo("Imported \(count)\u{00A0}\(noun) from Reminders", icon: "checklist")
    }

    /// J5: text captured via the global hotkey lands here. We own the
    /// BacklogService at this layer, so the insert plus its undo toast
    /// both live in one place. Trimming / empty gating already happened
    /// in `QuickCaptureView.commit`.
    func handleCapturedBacklogTask(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String,
              let backlog = optimizerService.backlogService else { return }
        let task = BacklogTask(title: text)
        backlog.addTask(task)
        let trimmed = text.count > 32 ? String(text.prefix(32)) + "\u{2026}" : text
        toastState.showSuccess(
            "Added \u{201C}\(trimmed)\u{201D}",
            icon: "plus.circle.fill"
        ) {
            _ = backlog.removeTask(id: task.id)
        }
    }

    /// ⇧↩ from quick-capture: route to the compact creation form
    /// pre-filled with the typed text. The prefill was also dropped
    /// into `QuickCaptureBridge.shared` so a closed-popover race still
    /// lands the user on the form via `.onAppear`.
    func handleCapturedBacklogTaskWithDetails(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        // Drain the bridge slot too — the notification path beat the
        // .onAppear consumer to it, and we don't want a duplicate
        // navigation when the popover finishes opening.
        _ = QuickCaptureBridge.shared.take()
        navigation = .newTask(prefillTitle: text, prefillDuration: nil)
    }

    /// Fires only for user-initiated completions in Bubo (the external-
    /// mirror path uses `silentlyComplete`, which bypasses this).
    func handleTaskCompletedNotification(_ notification: Notification) {
        guard let taskId = notification.object as? String else { return }
        let title = optimizerService.backlogService?
            .tasks.first(where: { $0.id == taskId })?.title
        let message = title.map { "\u{201C}\($0)\u{201D} marked done" } ?? "Marked done"
        toastState.showSuccess(message, icon: "checkmark.circle.fill")
    }
}
