import SwiftUI

// MARK: - Popover screen layout
//
// UI_REFACTORING.md stage 4: the visual contract of a popover screen
// as a type. Every full-screen destination assembles the same six
// slots in the same order:
//
//   header      title block / PopoverHeader (+ screen-specific summary)
//   actionRail  exactly one chip rail (or nothing)
//   status      exactly one status surface: banners, carousels
//   strips      context strips: world clock, colour filter, smart filter
//   content     the screen's body — fills the remaining height
//   footer      exactly one footer bar (actions / add-field / toolbar)
//
// A screen that wants a second action rail or a stacked banner has to
// fight this type — band drift becomes a compile-time argument instead
// of a screenshot surprise (PRINCIPLES §2).
//
// Slots are stacked at spacing 0: a slot that renders nothing (an empty
// status, a hidden action rail) takes no space and contributes no gap,
// so band drift can't sneak in through an empty frame (PRINCIPLES §2).
//
// Inter-band rhythm: the screens no longer add outer vertical padding at
// the slot call sites (the per-screen nudges that used to drift — a
// stray `.padding(.bottom)` here, a `.padding(.top)` there). Each band's
// vertical breathing room now comes from its own chrome alone, uniformly
// across screens. Frame margins that are NOT inter-band rhythm (e.g. a
// floating footer's bottom inset) legitimately stay at the call site.

struct PopoverScreenLayout<Header: View, ActionRail: View, Status: View, Strips: View, Content: View, Footer: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let actionRail: () -> ActionRail
    @ViewBuilder let status: () -> Status
    @ViewBuilder let strips: () -> Strips
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
            actionRail()
            status()
            strips()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer()
        }
    }
}
