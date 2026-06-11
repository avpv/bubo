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
// Conservative first adoption: slots receive the existing views WITH
// their current paddings, so geometry is bit-identical to the previous
// hand-rolled VStacks. Consolidating the inter-band rhythm into the
// scaffold (stripping children's outer paddings) is the follow-up that
// needs a visual pass — see the stage-4 notes in UI_REFACTORING.md.

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
