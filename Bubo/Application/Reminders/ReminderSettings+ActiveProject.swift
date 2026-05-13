import Foundation
import BuboDomain

// MARK: - ReminderSettings → AppleRemindersService bridge

extension ReminderSettings {
    /// Display name for the currently-active project, used as the filter
    /// key against `BacklogTask.context`. Returns `nil` for `.all` (no
    /// filter) or when the referenced project no longer exists (e.g. EK
    /// list deleted in Reminders.app, or stale local id).
    ///
    /// Lives here in the Bubo target (not in `Sources/Domain/`) because
    /// `AppleRemindersService` is an EventKit-backed service that the pure
    /// domain layer doesn't depend on.
    @MainActor
    func activeProjectTitle(remindersService: AppleRemindersService) -> String? {
        switch activeProject {
        case .all:
            return nil
        case .local(let id):
            return localProjects.first(where: { $0.id == id })?.name
        case .remindersList(let id):
            return remindersService.listRemindersLists().first(where: { $0.id == id })?.title
        }
    }
}
