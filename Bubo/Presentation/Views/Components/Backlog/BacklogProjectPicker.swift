import SwiftUI
import BuboDomain

// MARK: - Project picker

/// «Active project» switcher for the backlog header — a Reminders.app-style
/// pill that shows the current project name and opens a popover with all
/// available projects + an inline field for creating a new one.
///
/// Project sources (the menu view is the union of both):
///   1. **Local Bubo projects** (`settings.localProjects`) — always visible,
///      exist independently of EventKit. This gives the user a project
///      grouping of the backlog even without an Apple Reminders connection.
///   2. **Reminders lists** (via `AppleRemindersService`) — visible only
///      when EventKit access is granted AND sync is enabled. Grouped by
///      account (iCloud / Local / Exchange) — the same visual division
///      as in the native Reminders sidebar.
///
/// Semantics:
///   - `activeProject == .all` → pill reads as «All Tasks», backlog
///     is not filtered, new tasks go to `remindersExportListId`.
///   - `activeProject == .local(id)` → pill = local project, backlog
///     filtered by tasks with `task.context == project.name`. Sync with
///     Reminders is not performed for such tasks (target list = default).
///   - `activeProject == .remindersList(id)` → pill = EK list name,
///     backlog filtered by `task.context == list.title`, new tasks
///     land in that list.
///
/// Project creation **inline in the popover** — TextField lives right
/// above the list, in the style of `SlotPickerPopover`: the user can
/// immediately type the name of a new project or pick an existing one
/// below. Enter creates + activates + closes the popover, Esc cancels.
/// This keeps the user's focus in the backlog without blowing context
/// away with a modal, and without a separate «New Project…» item that
/// would require reaching for the mouse. When EK-sync is active, the
/// new project is also created automatically as an EKCalendar (so that
/// it appears on iPhone/iPad immediately); without sync — only a local project.
///
/// The picker is always visible: even without EventKit access, local
/// projects are a fully-fledged project entity, and a hidden button
/// would deprive the user of their only path to them.
@MainActor
struct BacklogProjectPicker: View {
    @Bindable var settings: ReminderSettings
    let remindersService: AppleRemindersService

    @Environment(\.activeSkin) private var skin

    /// Snapshot of `AppleRemindersService.hasAccess`, refreshed on
    /// `authorizationDidChange`. Holding it as `@State` (rather than
    /// reading the static directly inside `body`) makes EK-section
    /// visibility reactive: the moment the user grants permission, the
    /// notification flips this flag and SwiftUI re-renders the menu —
    /// the previous direct read could leave the section hidden until
    /// some unrelated state change triggered a redraw.
    @State private var hasRemindersAccess: Bool = AppleRemindersService.hasAccess

    /// Re-render trigger for EK list changes (creation, rename, deletion
    /// in Reminders.app or via iCloud sync). Computed properties read
    /// EventKit fresh; we just need a state value SwiftUI sees change to
    /// schedule a body re-evaluation.
    @State private var dataChangeTick: Int = 0

    /// Popover visibility. Replaces the previous native `Menu` so we can
    /// host an inline TextField inside the dropdown — `Menu` only accepts
    /// Buttons/Sections, no arbitrary content.
    @State private var isPopoverPresented: Bool = false

    /// Draft name typed into the inline create field at the top of the
    /// popover. Reset on every open so a previous abandoned draft doesn't
    /// linger between sessions.
    @State private var draftName: String = ""
    @FocusState private var isDraftFocused: Bool

    @State private var creationErrorMessage: String?

    private var ekListsByAccount: [(account: String, lists: [AppleRemindersService.RemindersList])] {
        // Touch the tick so SwiftUI tracks it as a dependency — without
        // this read the `onReceive` for `remindersDataChanged` wouldn't
        // refresh the menu when EK calendars change.
        _ = dataChangeTick
        return remindersService.listsByAccount()
    }

    private var showsEKSection: Bool {
        hasRemindersAccess && settings.isRemindersSyncEnabled
    }

    /// Title of the active project for the pill label and tooltip. `nil`
    /// when `.all` or when the referenced project no longer exists.
    private var activeTitle: String? {
        settings.activeProjectTitle(remindersService: remindersService)
    }

    private var canCreate: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Button {
            Haptics.tap()
            isPopoverPresented.toggle()
        } label: {
            pillLabel
        }
        .buttonStyle(.plain)
        .help(activeTitle.map { "Active project: \u{201C}\($0)\u{201D} — tap to switch" }
              ?? "All tasks across every project — tap to focus on one")
        .accessibilityLabel(activeTitle.map { "Active project \($0)" } ?? "All tasks")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            popoverContent
                .onAppear {
                    draftName = ""
                    // Defer focus to next runloop — TextField hasn't been
                    // mounted yet at the moment the popover appears.
                    DispatchQueue.main.async { isDraftFocused = true }
                }
        }
        .alert(
            "Couldn't create project",
            isPresented: Binding(
                get: { creationErrorMessage != nil },
                set: { if !$0 { creationErrorMessage = nil } }
            ),
            presenting: creationErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { creationErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        // EK access can flip at any moment (user grants in System Settings,
        // or via the in-app Connect button). React to the explicit signal
        // so the EK section appears the instant access lands.
        .onReceive(NotificationCenter.default.publisher(for: AppleRemindersService.authorizationDidChange)) { _ in
            hasRemindersAccess = AppleRemindersService.hasAccess
        }
        // EKEventStoreChanged fan-out — covers list creation/rename/delete
        // either in Reminders.app or via CloudKit sync.
        .onReceive(NotificationCenter.default.publisher(for: AppleRemindersService.remindersDataChanged)) { _ in
            dataChangeTick &+= 1
        }
    }

    // MARK: Popover content

    /// Custom popover layout: inline create field at the top (autofocused
    /// like in `SlotPickerPopover`), then the project list grouped the
    /// same way the native Menu used to render — All Tasks · Bubo
    /// projects · EK lists by account.
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            inlineCreateField

            SkinSeparator()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    allTasksRow

                    if !settings.localProjects.isEmpty {
                        sectionHeader("Bubo Projects")
                        ForEach(settings.localProjects) { project in
                            projectRow(
                                title: project.name,
                                icon: "folder",
                                isSelected: isSelected(.local(project.id))
                            ) {
                                Haptics.tap()
                                settings.activeProject = .local(project.id)
                                isPopoverPresented = false
                            }
                        }
                    }

                    if showsEKSection {
                        ForEach(ekListsByAccount, id: \.account) { group in
                            sectionHeader(group.account)
                            ForEach(group.lists) { list in
                                projectRow(
                                    title: list.title,
                                    icon: "list.bullet",
                                    isSelected: isSelected(.remindersList(list.id))
                                ) {
                                    Haptics.tap()
                                    settings.activeProject = .remindersList(list.id)
                                    isPopoverPresented = false
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(DS.Spacing.md)
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
        // Esc dismiss — same canonical pattern as `SlotPickerPopover`.
        .background(
            Button("", action: { isPopoverPresented = false })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    // MARK: Inline create

    /// TextField at the top of the popover — same role as the input in
    /// `SlotPickerPopover`: autofocused on appear so the user can start
    /// typing a new project name immediately, without first hunting for
    /// a «New Project…» menu item. Enter commits, Esc dismisses the
    /// whole popover (handled by the hidden cancel button).
    private var inlineCreateField: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "folder.badge.plus")
                .font(.footnote)
                .foregroundStyle(skin.accentColor)
            TextField("New project name\u{2026}", text: $draftName)
                .textFieldStyle(.plain)
                .font(DS.Typography.body(skin: skin))
                .foregroundStyle(skin.resolvedTextPrimary)
                .focused($isDraftFocused)
                .onSubmit(commitInlineCreate)
        }
        .padding(.vertical, DS.Spacing.xxs)
    }

    private func commitInlineCreate() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty input on Enter = no-op, keep the popover open so the
            // user can either keep typing or pick an existing project.
            return
        }

        // Local project always created — this is the canonical Bubo source
        // of truth regardless of whether an EK mirror exists.
        guard settings.addLocalProject(name: trimmed) != nil else {
            creationErrorMessage = "Project name can't be empty."
            draftName = ""
            return
        }

        // EK mirror: with sync on, also automatically create an EKCalendar
        // with the same name — so the new project appears on iPhone/iPad
        // immediately. The active project itself stays local: dual-source
        // is not needed as a cognitive load on the user, and export will
        // still pick up the EK list by name match via
        // `RemindersSyncService` (target = `remindersExportListId` /
        // default-list, which now contains our fresh list).
        if showsEKSection {
            do {
                _ = try remindersService.createList(name: trimmed)
            } catch {
                creationErrorMessage = "Project created locally, but couldn't add to Apple Reminders: \(error.localizedDescription)"
            }
        }

        Haptics.tap()
        draftName = ""
        isPopoverPresented = false
    }

    // MARK: Rows

    private var allTasksRow: some View {
        projectRow(
            title: "All Tasks",
            icon: "tray.full",
            isSelected: settings.activeProject == .all
        ) {
            Haptics.tap()
            settings.activeProject = .all
            isPopoverPresented = false
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        // Shared section-rubric voice (PRINCIPLES §8) — the same
        // SectionLabel the day headers and form sections use, instead
        // of a hand-tuned caption that drifted from it.
        SectionLabel(text: title)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.top, DS.Spacing.xs)
            .padding(.bottom, DS.Spacing.xxs)
    }

    @ViewBuilder
    private func projectRow(
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: isSelected ? "checkmark" : icon)
                    .font(.footnote)
                    .foregroundStyle(isSelected ? skin.accentColor : skin.resolvedTextSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(skin.accentColor.opacity(isSelected ? DS.Opacity.lightFill : 0))
            )
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ candidate: ActiveProject) -> Bool {
        settings.activeProject == candidate
    }

    // MARK: Pill label

    private var pillLabel: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: pillIcon)
                .font(.footnote)
            Text(activeTitle ?? "All Tasks")
                .font(.footnote.weight(.regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        .foregroundStyle(skin.resolvedTextSecondary)
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(skin.accentColor.opacity(0))
        )
        .overlay(
            Capsule().strokeBorder(
                skin.accentColor.opacity(DS.Opacity.borderIdle),
                lineWidth: DS.Border.thin
            )
        )
        .contentShape(Capsule())
    }

    private var pillIcon: String {
        switch settings.activeProject {
        case .all: return "tray.full"
        case .local: return "folder"
        case .remindersList: return "list.bullet"
        }
    }
}
