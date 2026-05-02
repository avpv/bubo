import SwiftUI

// MARK: - Project picker

/// «Active project» switcher для backlog header'а — Reminders.app-style
/// pill, который показывает имя текущего проекта и открывает меню со всеми
/// доступными проектами + пунктом «New Project…».
///
/// Источники проектов (вид меню — union обоих):
///   1. **Local Bubo projects** (`settings.localProjects`) — всегда видны,
///      существуют независимо от EventKit. Это даёт пользователю проектную
///      группировку backlog'а даже без подключения Apple Reminders.
///   2. **Reminders lists** (через `AppleRemindersService`) — видны только
///      когда есть EventKit-доступ И включена синхронизация. Группируются
///      по аккаунту (iCloud / Local / Exchange) — то же визуальное деление,
///      что и в нативном Reminders-сайдбаре.
///
/// Семантика:
///   - `activeProject == .all` → pill читается как «All Tasks», backlog
///     не фильтруется, новые задачи идут в `remindersExportListId`.
///   - `activeProject == .local(id)` → pill = local-проект, backlog
///     отфильтрован задачами с `task.context == project.name`. Sync с
///     Reminders для таких задач не делается (target list = default).
///   - `activeProject == .remindersList(id)` → pill = имя EK-листа,
///     backlog отфильтрован `task.context == list.title`, новые задачи
///     приземляются в этот лист.
///
/// «New Project…» открывает in-app popover с формой ввода имени; по
/// умолчанию создаёт local-проект, и (если включён EK-доступ + sync)
/// предлагает галочку «Also create list in Apple Reminders», чтобы
/// одновременно с Bubo-проектом завести EKCalendar и связать активный
/// проект с ним. Без галочки — только local-проект.
///
/// Picker виден всегда: даже без EventKit-доступа local-проекты —
/// полноценная проектная сущность, и спрятанная кнопка отнимала бы у
/// пользователя единственный путь к ним.
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
    /// in Reminders.app or via iCloud sync). The `lists` computed property
    /// reads EventKit fresh; we just need a state value SwiftUI sees
    /// change to schedule a body re-evaluation.
    @State private var dataChangeTick: Int = 0

    @State private var showingNewProjectPopover: Bool = false
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

    var body: some View {
        Menu {
            menuContent
        } label: {
            pillLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(activeTitle.map { "Active project: \u{201C}\($0)\u{201D} — tap to switch" }
              ?? "All tasks across every project — tap to focus on one")
        .accessibilityLabel(activeTitle.map { "Active project \($0)" } ?? "All tasks")
        .popover(isPresented: $showingNewProjectPopover, arrowEdge: .top) {
            NewProjectForm(
                canExportToReminders: showsEKSection,
                onCancel: { showingNewProjectPopover = false },
                onCreate: { name, alsoExport in
                    createNewProject(name: name, alsoExportToReminders: alsoExport)
                }
            )
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

    // MARK: Menu

    @ViewBuilder
    private var menuContent: some View {
        // «All Tasks» — fallback вид, в котором backlog показывает union
        // всех проектов. Полезен для глобального capacity-обзора без
        // привязки к одному проекту.
        Button {
            Haptics.tap()
            settings.activeProject = .all
        } label: {
            Label(
                "All Tasks",
                systemImage: settings.activeProject == .all ? "checkmark" : "tray.full"
            )
        }

        if !settings.localProjects.isEmpty {
            Divider()
            Section("Bubo Projects") {
                ForEach(settings.localProjects) { project in
                    Button {
                        Haptics.tap()
                        settings.activeProject = .local(project.id)
                    } label: {
                        Label(
                            project.name,
                            systemImage: isSelected(.local(project.id)) ? "checkmark" : "folder"
                        )
                    }
                }
            }
        }

        if showsEKSection {
            Divider()
            ForEach(ekListsByAccount, id: \.account) { group in
                Section(group.account) {
                    ForEach(group.lists) { list in
                        Button {
                            Haptics.tap()
                            settings.activeProject = .remindersList(list.id)
                        } label: {
                            Label(
                                list.title,
                                systemImage: isSelected(.remindersList(list.id)) ? "checkmark" : "list.bullet"
                            )
                        }
                    }
                }
            }
        }

        Divider()

        Button {
            Haptics.tap()
            showingNewProjectPopover = true
        } label: {
            Label("New Project…", systemImage: "folder.badge.plus")
        }
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
                .font(.footnote.weight(.medium))
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

    // MARK: Create

    private func createNewProject(name: String, alsoExportToReminders: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Local project always created — that's the canonical Bubo
        // representation, independent of whether EK is also involved.
        guard settings.addLocalProject(name: trimmed) != nil else {
            creationErrorMessage = "Project name can't be empty."
            return
        }

        // Optional EK companion list. When the user opted in *and* sync is
        // available, also create a Reminders list with the same name —
        // tasks tagged with this project will then export to that list via
        // `RemindersSyncService` once the active project is switched to
        // the EK side. We don't auto-switch the active project to EK on
        // success — local stays the source of truth; the user can flip if
        // they want EK-backed behaviour.
        if alsoExportToReminders, showsEKSection {
            do {
                _ = try remindersService.createList(name: trimmed)
            } catch {
                creationErrorMessage = "Local project created, but couldn't add to Apple Reminders: \(error.localizedDescription)"
            }
        }

        showingNewProjectPopover = false
        Haptics.tap()
    }
}

// MARK: - New project form

/// In-app popover form for «New Project…», used in place of the system
/// `.alert()` so the creation surface lives inside Bubo's window, in
/// Bubo's design system. Trades the system alert's «sheet of paper»
/// affordance for: focus on the title field on appear, a Cancel/Create
/// pair that matches `EditTaskView`/`NewTaskView`, and an opt-in
/// «mirror to Reminders» toggle that the system alert couldn't host.
private struct NewProjectForm: View {
    let canExportToReminders: Bool
    let onCancel: () -> Void
    let onCreate: (_ name: String, _ alsoExport: Bool) -> Void

    @Environment(\.activeSkin) private var skin

    @State private var name: String = ""
    @State private var alsoExport: Bool = false
    @FocusState private var isNameFocused: Bool

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("New Project")
                .font(DS.Typography.headline(skin: skin))
                .foregroundStyle(skin.resolvedTextPrimary)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit { submit() }
                Text("Tasks tagged with this project will be grouped together in the backlog.")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }

            if canExportToReminders {
                Toggle(isOn: $alsoExport) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also create list in Apple Reminders")
                            .font(.footnote.weight(.medium))
                        Text("So new tasks also appear on iPhone / iPad.")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }
                .toggleStyle(.switch)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: 320)
        .onAppear { isNameFocused = true }
    }

    private func submit() {
        guard isValid else { return }
        onCreate(name, alsoExport)
    }
}
