import SwiftUI
import AppKit

/// Footer of the popover. Three controls share one row: a primary
/// «Add» split-menu (⌘N opens the unified Quick Add; the detailed New
/// Event / New Task forms live as menu escapes), a borderless «Tasks»
/// link (⌘T) and an ellipsis «More» menu (refresh, settings, quit).
///
/// PRINCIPLES §1: one primary action, dominant. The trailing edge
/// speaks one borderless voice — `Tasks` and `More` use the same
/// subdued `subheadline` style so they don't fight each other or the
/// loud `Add` button.
struct FooterActions: View {
    @Binding var navigation: MenuBarNavigation
    let reminderService: ReminderService
    let toastState: ToastState
    /// Presentation flag for the unified Quick Add popover anchored on
    /// the primary button. Owned by the screen model so the global ⌘N
    /// path and the button share one source of truth.
    @Binding var quickAddPresented: Bool
    /// Commit a Quick Add task interpretation (title, explicit minutes).
    let onQuickAddTask: (String, Int?) -> Void
    /// Commit a Quick Add event interpretation (title, start, minutes).
    let onQuickAddEvent: (String, Date, Int) -> Void
    /// ⇧↩ in Quick Add — open the matching detailed form pre-filled.
    let onQuickAddDetails: (QuickAddParser.Interpretation) -> Void
    /// Settings-derived skin (`settings.selectedSkin`), used by
    /// `.skinBarBackground` and the ellipsis menu's `.tint`.
    /// Identical to the `@Environment(.activeSkin)` value the host
    /// publishes; passed explicitly because `.skinBarBackground` is
    /// part of the bar styling, not the content.
    let activeSkin: SkinDefinition
    /// Optional working-hours window — needed by the "Copy
    /// availability" menu item (S2 fix) so the listed free slots
    /// honour the user's actual workday. nil = the menu item is
    /// hidden; preview surfaces and call sites that don't wire the
    /// optimizer keep their previous footer behaviour.
    var workingHours: ClosedRange<Int>? = nil
    /// Optional explicit working-days set (`Calendar.weekday`
    /// integers, 1 = Sunday). Filters Saturday / Sunday out of the
    /// copy-availability list when the user's workdays are
    /// Mon–Fri. nil = no day filter applied.
    var workingDays: Set<Int>? = nil

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
                    Label("New Event\u{2026}", systemImage: "calendar.badge.plus")
                }
                Button {
                    Haptics.tap()
                    navigation = .newTask(prefillTitle: "", prefillDuration: nil)
                } label: {
                    Label("New Task\u{2026}", systemImage: "plus.circle")
                }
            } label: {
                // «Add» is now honest: the primary action is the unified
                // Quick Add (UX_AUDIT.md F8) — one field that routes free
                // text to a task or an event by rule, instead of making
                // the user pick a vocabulary first. The detailed forms
                // stay one step away as menu escapes and via ⇧↩.
                Label("Add", systemImage: "plus")
            } primaryAction: {
                Haptics.tap()
                quickAddPresented = true
            }
            .buttonStyle(.action(role: .primary))
            .help("Add a task or event (\u{2318}N) — e.g. \u{201C}Write report 30m\u{201D} or \u{201C}Lunch 13:00\u{201D}")
            .keyboardShortcut("n", modifiers: .command)
            .popover(isPresented: $quickAddPresented, arrowEdge: .top) {
                QuickAddView(
                    onAddTask: onQuickAddTask,
                    onAddEvent: onQuickAddEvent,
                    onDetails: onQuickAddDetails,
                    onDismiss: { quickAddPresented = false }
                )
            }

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
            .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .regular))
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

                // S2 — "Don't show the chaos". One quick action that
                // emits the next 3 free slots in copy-ready plain text
                // so the user can paste them into Slack / Mail / iMessage
                // without revealing their actual calendar. Hidden when
                // the host hasn't wired `workingHours` (preview surfaces).
                if let hours = workingHours {
                    Button {
                        Haptics.tap()
                        let copied = AvailabilityComposer.copyToPasteboard(
                            events: reminderService.allEvents,
                            workingHours: hours,
                            workingDays: workingDays,
                            limit: 3
                        )
                        if copied > 0 {
                            toastState.showSuccess(
                                copied == 1
                                    ? "Copied 1\u{00A0}free slot"
                                    : "Copied \(copied)\u{00A0}free slots",
                                icon: "doc.on.clipboard.fill"
                            )
                        } else {
                            toastState.showInfo(
                                "No free slots in the next week",
                                icon: "doc.on.clipboard"
                            )
                        }
                    } label: {
                        Label("Copy availability\u{2026}", systemImage: "doc.on.clipboard")
                    }
                    .help("Copy the next 3 free slots to the clipboard")
                }

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
            .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .regular))
            .foregroundStyle(skin.resolvedTextSecondary)
            .symbolRenderingMode(.monochrome)
            .tint(activeSkin.resolvedToolbarTint)
            .help("More")
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(activeSkin)
        // Top hairline separates the footer from the list above —
        // matches the prototype's `border-top 0.5 px rgba(0,0,0,0.06)`
        // and keeps the same `fg-1` 8 % rhythm as the timeline /
        // backlog row strokes so the surface reads as one product.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider))
                .frame(height: DS.Border.thin)
                .allowsHitTesting(false)
        }
    }
}
