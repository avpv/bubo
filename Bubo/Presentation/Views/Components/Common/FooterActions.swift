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
            // `.regular` size hugs the «Add event» content (~110 pt) instead
            // of the previous `.flexible` minWidth-100 / lg-padding shape
            // that stretched the CTA past half the footer width. The button
            // still reads as the primary verb (gradient / accent fill via
            // the skin), it just no longer dwarfs the trailing actions.
            .buttonStyle(.action(role: .primary, size: .regular))
            .help("Add a new event (\u{2318}N)")
            .keyboardShortcut("n", modifiers: .command)

            Spacer()

            // Tasks — secondary, sits inside a quiet capsule so it reads as
            // a real navigation chip next to the primary CTA. The previous
            // borderless text label fought the gradient CTA at a glance —
            // a chip pairs with the «More» icon-button next to it under one
            // visual voice without claiming primary attention.
            Button {
                Haptics.tap()
                navigation = .backlog
            } label: {
                Text("Tasks")
                    .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .frame(height: DS.Size.chipHeight)
                    .background(
                        Capsule().fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceChip))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider),
                            lineWidth: DS.Border.thin
                        )
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
            .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
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
