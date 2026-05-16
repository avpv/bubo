import SwiftUI

// MARK: - EventRowView: Title (display + inline-edit)
//
// Inline title rename gating and commit/cancel paths.
// Extracted from EventRowView.swift.

extension EventRowView {

    // MARK: - Title (display + inline-edit)

    /// Title cell. Renders a `TextField` while `isEditingTitle` is true,
    /// otherwise a `Text` carrying a `simultaneousGesture` for double-tap
    /// rename — single taps still propagate to the parent row Button.
    /// Inline edit is gated to local (Bubo-owned) events; Apple Calendar
    /// titles are read-only.
    @ViewBuilder
    var titleField: some View {
        if isEditingTitle {
            TextField("", text: $titleDraft)
                .textFieldStyle(.plain)
                // Match the rendered title's weight (PRINCIPLES §8) so
                // the inline-edit field doesn't visibly shift when the
                // user double-clicks to rename.
                .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: skin.resolvedHeadlineFontWeight))
                .focused($titleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onExitCommand { cancelTitleEdit() }
                .onChange(of: titleFieldFocused) { _, isFocused in
                    // Blur (clicking elsewhere or tabbing out) commits,
                    // matching Finder rename behaviour. Pressing Esc
                    // takes the cancel path before this fires because
                    // `cancelTitleEdit()` clears `isEditingTitle` first.
                    if !isFocused && isEditingTitle {
                        commitTitleEdit()
                    }
                }
                .padding(.vertical, DS.Spacing.hairline)
                .padding(.horizontal, DS.Spacing.xs)
                // Apple-philosophy inline-rename idiom (Finder pattern):
                // ONE surface — a single hairline focus ring in the
                // accent colour. The previous version drew BOTH a
                // fill AND a strokeBorder; two surfaces on the same
                // text field. One stroke, no fill, content stays
                // anchored to its baseline.
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius)
                        .strokeBorder(skin.accentColor.opacity(DS.Opacity.softAccent),
                                       lineWidth: DS.Border.standard)
                )
                .accessibilityLabel("Edit event title")
        } else {
            Text(event.title)
                // Title is one step bolder than the meta line below it —
                // PRINCIPLES §8: headline weight is derived from body
                // weight, never set per-skin. Matches prototype 13/600
                // when the active skin uses regular body.
                .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: skin.resolvedHeadlineFontWeight))
                .lineLimit(2)
                .truncationMode(.tail)
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            beginTitleEditIfAllowed()
                        }
                )
        }
    }

    var canRenameInline: Bool {
        event.isLocalEvent && onRenameLocal != nil
    }

    func beginTitleEditIfAllowed() {
        guard canRenameInline else { return }
        Haptics.tap()
        titleDraft = event.title
        isEditingTitle = true
        // Defer focusing one runloop tick so the TextField is in the
        // hierarchy by the time we ask SwiftUI to focus it.
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty title or unchanged title → cancel quietly. An empty
        // rename is treated as «I changed my mind», not «delete me».
        if trimmed.isEmpty || trimmed == event.title {
            cancelTitleEdit()
            return
        }
        onRenameLocal?(event, trimmed)
        Haptics.impact()
        isEditingTitle = false
        titleFieldFocused = false
    }

    func cancelTitleEdit() {
        isEditingTitle = false
        titleFieldFocused = false
        titleDraft = ""
    }

}
