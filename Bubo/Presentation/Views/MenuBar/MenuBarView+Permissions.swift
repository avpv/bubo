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

    /// Permissions banners shown in the popover header. Order matches a
    /// stable left-to-right reading order: Calendar first, Reminders next.
    /// When more than one entry exists, `PermissionBannersCarousel`
    /// turns into a horizontal pager.
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
    /// the banner reflects access changes from both the in-app Connect
    /// button and System Settings while the popover is open.
    ///
    /// Never downgrades a known grant to `.notDetermined` — the static
    /// EventKit query is occasionally stale right after a grant (TCC
    /// propagation lag on the shared store), and `.notDetermined` isn't
    /// reachable from `.fullAccess` without the user revoking via
    /// System Settings, which the OS reports as `.denied`. Mirrors the
    /// same guard in `SettingsViewModel.refreshRemindersAuthStatus`.
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
    /// haven't yet seen any events arrive AND haven't escalated to the
    /// «taking long» message via the 3 s timeout. Permission
    /// banners (no access) take precedence — the empty popover with a
    /// permission banner already explains itself.
    var showSyncingState: Bool {
        guard hasStartedSync else { return false }
        guard !initialSyncDataArrived else { return false }
        // Don't shadow the existing permission banner — it already names
        // the cause and offers a fix.
        guard permissionBannerSpecs.isEmpty else { return false }
        return reminderService.allEvents.isEmpty
    }
}
