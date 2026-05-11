import SwiftUI
import AppKit

/// Footer of the popover. Three controls share one row: a primary
/// «Add event» split-menu (⌘N + a New Task secondary), a borderless
/// «Tasks» link (⌘T) and an ellipsis «More» menu (refresh, settings,
/// quit).
///
/// PRINCIPLES §1: one primary action, dominant. The trailing edge
/// speaks one borderless voice — `Tasks` and `More` use the same
/// subdued `subheadline` style so they don't fight each other or the
/// loud `Add event` button.
struct FooterActions: View {
    @Binding var navigation: MenuBarNavigation
    let reminderService: ReminderService
    let toastState: ToastState
    /// Settings-derived skin (`settings.selectedSkin`), used by
    /// `.skinBarBackground` and the ellipsis menu's `.tint`.
    /// Identical to the `@Environment(.activeSkin)` value the host
    /// publishes; passed explicitly because `.skinBarBackground` is
    /// part of the bar styling, not the content.
    let activeSkin: SkinDefinition

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack {
            // Primary CTA — `.flexible` size = minWidth 100, lg internal
            // horizontal padding. AddEventView's primary uses the same
            // treatment so both screens' primary actions carry equal
            // weight.
            Menu {
                Button {
                    Haptics.tap()
                    navigation = .addEvent()
                } label: {
                    // HIG: surface keyboard shortcut hints in menu items so
                    // users can graduate from clicking to typing.
                    Label("New Event   \u{2318}N", systemImage: "calendar.badge.plus")
                }
                Button {
                    Haptics.tap()
                    navigation = .backlog
                } label: {
                    Label("New Task   \u{21E7}\u{2318}N", systemImage: "plus.circle")
                }
            } label: {
                // «Add event» mirrors the prototype's
                // `ui_kits/menubar/index.html` `.add-btn` copy. The
                // primary action of this Menu button IS the new-event
                // form (⌘N) — `New Task` lives as a secondary menu
                // item below — so naming the loud button after its
                // primary verb tells the eye what tapping does. The
                // generic «Add» reading under-promised the dominant
                // action and over-promised parity with «Tasks» (a
                // navigation, not a verb).
                Label("Add event", systemImage: "plus")
            } primaryAction: {
                Haptics.tap()
                navigation = .addEvent()
            }
            .buttonStyle(.action(role: .primary))
            .help("Add a new event (\u{2318}N)")
            .keyboardShortcut("n", modifiers: .command)

            Spacer()

            // Tasks — secondary, borderless. Routes to the backlog screen
            // where task creation lives in its own composer. PRINCIPLES §1:
            // shares the trailing edge with `More` under a single style.
            Button {
                Haptics.tap()
                navigation = .backlog
            } label: {
                Text("Tasks")
            }
            .buttonStyle(.borderless)
            // PRINCIPLES §8: type sizes come from macOS text styles, not
            // hand-tuned points. `subheadline` reads one step below the
            // primary `Add` and pairs with the same subdued role for
            // `More` next to it (§1: one borderless voice on the
            // trailing edge).
            .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
            .foregroundStyle(skin.resolvedTextSecondary)
            .keyboardShortcut("t", modifiers: .command)
            .help("Open backlog (\u{2318}T)")

            Menu {
                Button {
                    Haptics.tap()
                    reminderService.syncNow()
                    toastState.showInfo("Refreshing\u{2026}", icon: "arrow.clockwise")
                } label: {
                    Label("Refresh Calendars", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                OpenSettingsButton()
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Quit Bubo", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // PRINCIPLES §8: replace hand-tuned 14pt with the macOS
            // `subheadline` style so the trailing edge speaks one
            // consistent voice with the `Tasks` button next to it.
            .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
            .foregroundStyle(skin.resolvedTextSecondary)
            .symbolRenderingMode(.monochrome)
            .tint(activeSkin.resolvedToolbarTint)
            .help("More")
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(activeSkin)
    }
}
