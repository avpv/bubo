import SwiftUI

// MARK: - Permissions + Cold-Start Sync State
//
// EventKit access lives outside the Observation system — `hasAccess`
// is a non-observable static call, so the view body cannot react to
// it directly. We mirror the per-store grants into `@State` and
// refresh them on appear and on the services' `authorizationDidChange`
// notifications; the banner then disappears immediately when the user
// grants access via Settings.
//
// `showSyncingState` belongs to the same cluster because both surfaces
// are about «do we have data yet, and if not, why» — permissions
// banners take precedence over the syncing panel.

extension MenuBarView {

    /// Actionable permission banners for the popover's status slot.
    /// Stable reading order: Calendar first, Reminders next. Each entry
    /// renders as a clickable `PermissionBannerRow` that deep-links to
    /// the Settings pane that fixes it.
    var permissionBannerSpecs: [PermissionBannerSpec] {
        var specs: [PermissionBannerSpec] = []
        if settings.isCalendarSyncEnabled && !calendarHasAccess {
            specs.append(.calendar)
        }
        if settings.isRemindersSyncEnabled && !remindersHasAccess {
            specs.append(.reminders)
        }
        return specs
    }

    /// Re-reads the EventKit permission snapshots into `@State`. Called on
    /// appear and whenever the services post `authorizationDidChange`, so
    /// downstream state (empty-state copy, sync gating) reflects access
    /// changes from both the in-app Connect button and System Settings
    /// while the popover is open.
    func refreshPermissionSnapshots() {
        let calendarStatus = AppleCalendarService.authorizationStatus
        let remindersStatus = AppleRemindersService.authorizationStatus
        let calendar = (calendarHasAccess && calendarStatus == .notDetermined)
            ? true
            : calendarStatus == .fullAccess
        let reminders = (remindersHasAccess && remindersStatus == .notDetermined)
            ? true
            : remindersStatus == .fullAccess
        if calendarHasAccess != calendar { calendarHasAccess = calendar }
        if remindersHasAccess != reminders { remindersHasAccess = reminders }
    }

    /// Whether the «Syncing calendars…» panel should replace the empty
    /// state on cold start. Active while we've kicked off a sync but
    /// haven't yet seen any events arrive. Gated off when calendar
    /// access is missing — the empty state with «Adjust calendars»
    /// link covers that case directly.
    var showSyncingState: Bool {
        guard hasStartedSync else { return false }
        guard !initialSyncDataArrived else { return false }
        let needsCalendarAccess = settings.isCalendarSyncEnabled && !calendarHasAccess
        let needsRemindersAccess = settings.isRemindersSyncEnabled && !remindersHasAccess
        guard !needsCalendarAccess, !needsRemindersAccess else { return false }
        return reminderService.allEvents.isEmpty
    }
}
