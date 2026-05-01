import SwiftUI

// MARK: - Project picker

/// «Active project» switcher для backlog header'а — Reminders.app-style
/// pill, который показывает имя текущего листа и открывает меню со всеми
/// доступными Reminders-листами + пунктом «New Project…».
///
/// Семантика:
///   - `activeProjectListId == nil` → pill читается как «All Tasks»,
///     backlog не фильтруется, новые задачи идут в `remindersExportListId`.
///   - `activeProjectListId == X` → pill читается как имя листа X,
///     backlog отфильтрован задачами с `task.context == X.title`,
///     новые задачи приземляются в лист X (см. `RemindersSyncService`).
///   - «New Project…» создаёт пустой `EKCalendar(for: .reminder)` через
///     `AppleRemindersService.createList(name:)` и сразу переключает
///     активный проект на свежий id — пользователь оказывается «в новом
///     списке» одним движением, как в Reminders.app.
///
/// Виден только когда есть EventKit-доступ к Reminders и sync-toggle
/// включён. Без этих условий «проектов» в Bubo физически не существует
/// (`context` остаётся как мягкий тэг), и picker скрывается, чтобы не
/// дразнить пустым меню.
@MainActor
struct BacklogProjectPicker: View {
    @Bindable var settings: ReminderSettings
    let remindersService: AppleRemindersService

    @Environment(\.activeSkin) private var skin

    @State private var newProjectName: String = ""
    @State private var showingNewProjectAlert: Bool = false
    @State private var creationErrorMessage: String?

    /// EventKit может позвать нас перерисоваться, когда пользователь
    /// добавит/удалит/переименует лист в Reminders.app — `lists` читается
    /// заново при каждом рендере, чтобы меню не показывало stale-имена.
    private var lists: [AppleRemindersService.RemindersList] {
        remindersService.listRemindersLists()
    }

    private var activeListTitle: String? {
        guard let id = settings.activeProjectListId else { return nil }
        return lists.first(where: { $0.id == id })?.title
    }

    var body: some View {
        // Скрываем picker, если EventKit-доступа нет ИЛИ sync выключен —
        // в этом состоянии листов в Bubo не существует. Когда пользователь
        // включит sync, picker появится автоматически (settings @Observable).
        if AppleRemindersService.hasAccess, settings.isRemindersSyncEnabled {
            Menu {
                menuContent
            } label: {
                pillLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(activeListTitle.map { "Active project: \u{201C}\($0)\u{201D} — tap to switch" }
                  ?? "All tasks across every list — tap to focus on one")
            .accessibilityLabel(activeListTitle.map { "Active project \($0)" } ?? "All tasks")
            .alert("New Project", isPresented: $showingNewProjectAlert) {
                TextField("Project name", text: $newProjectName)
                Button("Create") { createNewProject() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    newProjectName = ""
                }
            } message: {
                Text("Creates a new list in Apple Reminders and switches to it.")
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
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var menuContent: some View {
        // «All Tasks» — fallback вид, в котором backlog показывает union
        // всех листов. Полезен, когда пользователь хочет глобальный
        // capacity-обзор без привязки к конкретному проекту.
        Button {
            Haptics.tap()
            settings.activeProjectListId = nil
        } label: {
            Label("All Tasks", systemImage: settings.activeProjectListId == nil ? "checkmark" : "tray.full")
        }

        Divider()

        // Группируем листы по аккаунту (iCloud / Local / Exchange) — то же
        // визуальное деление, что и в нативном Reminders-сайдбаре, чтобы
        // пользователь сразу узнавал свои листы.
        let grouped = remindersService.listsByAccount()
        ForEach(grouped, id: \.account) { group in
            Section(group.account) {
                ForEach(group.lists) { list in
                    Button {
                        Haptics.tap()
                        settings.activeProjectListId = list.id
                    } label: {
                        Label(
                            list.title,
                            systemImage: settings.activeProjectListId == list.id ? "checkmark" : "list.bullet"
                        )
                    }
                }
            }
        }

        Divider()

        Button {
            Haptics.tap()
            newProjectName = ""
            showingNewProjectAlert = true
        } label: {
            Label("New Project…", systemImage: "folder.badge.plus")
        }
    }

    // MARK: Pill label

    private var pillLabel: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: settings.activeProjectListId == nil ? "tray.full" : "list.bullet")
                .font(.footnote)
            Text(activeListTitle ?? "All Tasks")
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

    // MARK: Create

    private func createNewProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { newProjectName = "" }
        guard !name.isEmpty else { return }
        do {
            let listId = try remindersService.createList(name: name)
            settings.activeProjectListId = listId
            Haptics.tap()
        } catch {
            creationErrorMessage = error.localizedDescription
        }
    }
}
