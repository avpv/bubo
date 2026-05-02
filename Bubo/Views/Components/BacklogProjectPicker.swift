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
/// «New Project…» **не открывает модальное окно** — pill сам превращается
/// в инлайн text-field прямо в шапке backlog'а, как переименование item'а
/// в Reminders.app-сайдбаре. Enter создаёт проект, Esc отменяет. Это
/// держит фокус пользователя в backlog'е без сноса контекста модалкой.
/// Когда EK-sync активен, новый проект автоматически создаётся и как
/// EKCalendar (чтобы он появился на iPhone/iPad); без sync'а — только
/// local-проект.
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
    /// in Reminders.app or via iCloud sync). Computed properties read
    /// EventKit fresh; we just need a state value SwiftUI sees change to
    /// schedule a body re-evaluation.
    @State private var dataChangeTick: Int = 0

    /// Inline-create mode: when `true`, the pill renders an editable
    /// TextField in place of its label. No modal — Enter commits, Esc
    /// (or focus loss with empty input) cancels. This is the "Birman:
    /// объекты, а не диалоги" path: creating a project doesn't yank the
    /// user out of the backlog into a separate sheet.
    @State private var isCreating: Bool = false
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

    var body: some View {
        Group {
            if isCreating {
                inlineCreateField
            } else {
                projectMenu
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

    // MARK: Menu (default state)

    private var projectMenu: some View {
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
    }

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
            beginInlineCreate()
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

    // MARK: Inline create

    /// Pill в режиме создания: вместо лейбла рисует TextField в той же
    /// капсуле и тех же spacing'ах, чтобы переход «нажал → печатаешь»
    /// читался как изменение состояния одного и того же элемента, а не
    /// как появление новой панели. Иконка папки слева — affordance того,
    /// что мы создаём проект; цветной accent-stroke вокруг капсулы
    /// сигналит «активный input».
    private var inlineCreateField: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: "folder.badge.plus")
                .font(.footnote)
                .foregroundStyle(skin.accentColor)
            TextField("New project name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .focused($isDraftFocused)
                .onSubmit { commitInlineCreate() }
                .onExitCommand { cancelInlineCreate() }
                .frame(minWidth: 120, maxWidth: 200)
            Button {
                cancelInlineCreate()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
        )
        .overlay(
            Capsule().strokeBorder(
                skin.accentColor.opacity(DS.Opacity.softAccent),
                lineWidth: DS.Border.thin
            )
        )
        .contentShape(Capsule())
        .accessibilityLabel("New project name")
    }

    private func beginInlineCreate() {
        draftName = ""
        isCreating = true
        // Defer focus to next runloop — TextField hasn't been mounted
        // yet at the moment the user taps the menu item, and focusing a
        // not-yet-visible field is a no-op.
        DispatchQueue.main.async { isDraftFocused = true }
    }

    private func cancelInlineCreate() {
        isCreating = false
        draftName = ""
    }

    private func commitInlineCreate() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty input on Enter = cancel, не создавать пустой проект
            // и не показывать алерт — пользователь явно ничего не ввёл.
            cancelInlineCreate()
            return
        }

        // Local project always created — это каноничный Bubo-источник
        // правды независимо от того, есть ли EK-зеркало.
        guard settings.addLocalProject(name: trimmed) != nil else {
            creationErrorMessage = "Project name can't be empty."
            cancelInlineCreate()
            return
        }

        // EK-зеркало: при включённом sync'е автоматически создаём ещё и
        // EKCalendar с тем же именем — чтобы новый проект сразу появился
        // на iPhone/iPad. Сам активный проект остаётся local: dual-source
        // не нужен пользователю как когнитивная нагрузка, а export всё
        // равно подхватит EK-лист по совпадению имени через
        // `RemindersSyncService` (target = `remindersExportListId` /
        // default-list, который теперь содержит наш свежий лист).
        if showsEKSection {
            do {
                _ = try remindersService.createList(name: trimmed)
            } catch {
                creationErrorMessage = "Project created locally, but couldn't add to Apple Reminders: \(error.localizedDescription)"
            }
        }

        Haptics.tap()
        cancelInlineCreate()
    }
}
