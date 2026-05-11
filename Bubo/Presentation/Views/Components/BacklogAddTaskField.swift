import SwiftUI

/// Inline add-task field for the fullscreen Backlog. Mirror of the
/// inline `BacklogView`'s composer (without ghost-preview — there's no
/// timeline here and nowhere to predict a slot). Includes the same
/// three affordances as the inline version: syntax-teaching placeholder
/// in empty state, empty-state hint, focused-state shortcut hint — so
/// that the fullscreen card and inline card teach identically.
///
/// Owns no state itself: the host owns the `@State`/`@FocusState` for
/// the title, parsed title, and focus, and forwards them via @Binding /
/// @FocusState.Binding so the parser .onChange and the `.onExitCommand`
/// clear path stay symmetric. The two action verbs (`addTask`,
/// `openCreateWithDetails`) come in as closures.
struct BacklogAddTaskField: View {
    @Binding var newTaskTitle: String
    @Binding var parsedNewTaskTitle: (cleaned: String, durationMinutes: Int?)
    @FocusState.Binding var isInputFocused: Bool
    /// Drives the empty-state hint copy under the field; passed in by
    /// the host so the source of truth stays singular.
    let activeTasksIsEmpty: Bool
    /// Whether the host wired an `onCreateTaskWithDetails` callback.
    /// Gates the trailing chevron + the «Details» kbd hint.
    let canCreateWithDetails: Bool
    let onSubmit: () -> Void
    let onShiftSubmit: () -> Void

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// TextField placeholder. Teaching syntax when the backlog is empty
    /// («try: Write report 30m»), compact «Add task…» otherwise.
    /// Identical copy to inline BacklogView.
    private var placeholder: String {
        activeTasksIsEmpty
            ? "Add task — try: Write report 30m"
            : "Add task\u{2026}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.footnote)
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(skin.accentColor) : AnyShapeStyle(skin.resolvedTextSecondary))

                TextField(placeholder, text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.body(skin: skin))
                    .focused($isInputFocused)
                    .onSubmit { onSubmit() }
                    .onKeyPress(keys: [.return]) { press in
                        // ⇧↩ — open compact creation form. Mirrors the
                        // inline BacklogView so muscle memory carries
                        // between surfaces.
                        guard press.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        onShiftSubmit()
                        return .handled
                    }
                    .onExitCommand {
                        newTaskTitle = ""
                        parsedNewTaskTitle = ("", nil)
                        isInputFocused = false
                    }

                // Mirrors the inline `BacklogView` chip pair: explicit
                // parse → accent capsule (committed-looking), verb guess
                // → quiet `~30m` in machineHint voice (advisory). One
                // visual rhythm across both backlog surfaces.
                if let minutes = parsedNewTaskTitle.durationMinutes {
                    Text(DS.formatMinutes(minutes))
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityLabel("Parsed duration: \(DS.formatMinutes(minutes))")
                } else if !parsedNewTaskTitle.cleaned.isEmpty,
                          let guess = BacklogTitleParser.guessDuration(for: parsedNewTaskTitle.cleaned) {
                    Text("~\(DS.formatMinutes(guess))")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .transition(.opacity)
                        .accessibilityLabel("Guessed duration: about \(DS.formatMinutes(guess))")
                }

                // Trailing "›" — mouse equivalent of ⇧↩, shown only while
                // the input is focused so it doesn't compete for attention
                // when nobody's typing.
                if isInputFocused, canCreateWithDetails {
                    Button(action: onShiftSubmit) {
                        Image(systemName: "chevron.right.circle")
                            .font(DS.Typography.body(skin: skin))
                            .foregroundStyle(skin.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add with details (\u{21E7}\u{23CE})")
                    .accessibilityLabel("Add task with details")
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(skin.accentColor.opacity(isInputFocused ? DS.Opacity.lightFill : DS.Opacity.subtleFill))
            )
            // Idle stroke makes the input read as a field on every wallpaper.
            // Mirrors the inline BacklogView treatment so both backlog modes
            // share the same affordance language.
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .strokeBorder(
                        skin.accentColor.opacity(isInputFocused ? DS.Opacity.softAccent : DS.Opacity.borderIdle),
                        lineWidth: isInputFocused ? DS.Border.selection : DS.Border.standard
                    )
            )
            .motionAwareAnimation(DS.Animation.quick, value: parsedNewTaskTitle.durationMinutes, reduceMotion: reduceMotion)

            // Hint for new users — disappears once they add a task. Same
            // copy as inline BacklogView so the empty-state lesson is
            // identical across surfaces.
            if activeTasksIsEmpty && !isInputFocused {
                Text("Tasks you add here will be scheduled into free slots")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .transition(.opacity)
            }

            // Persistent shortcut hints — match the prototype's
            // `ui_kits/backlog/index.html` `.hints` row that sits
            // below the composer regardless of focus. The teaching
            // value of the affordance is highest BEFORE the user
            // taps in, not after; the focused-only behaviour we used
            // before hid the lesson from the audience that needed it
            // most. The `Cancel` hint is gated on focus because Esc
            // is a no-op when the field is idle — showing it always
            // would be misleading.
            HStack(spacing: DS.Spacing.sm) {
                kbdHint(key: "\u{23CE}", label: "Add")
                if canCreateWithDetails {
                    kbdHint(key: "\u{21E7}\u{23CE}", label: "Details")
                }
                if isInputFocused {
                    kbdHint(key: "\u{238B}", label: "Cancel")
                }
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
        }
        // Match BacklogView's add-field padding so the field sits at the
        // same offset from the card edge as the inline version.
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        .motionAwareAnimation(DS.Animation.quick, value: isInputFocused, reduceMotion: reduceMotion)
    }

    /// Single kbd-shortcut hint rendered as «[⏎] Add» — a tinted mono
    /// badge for the key glyph followed by the action's plain-text
    /// label. Mirrors the prototype's `.hints .k` styling (mono font,
    /// 7 % fg-tint background, small radius) so each shortcut reads
    /// as one unit instead of a wall of glyph + text + interpunct.
    @ViewBuilder
    private func kbdHint(key: String, label: String) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Text(key)
                // PRINCIPLES §8: prefer a macOS text style over a
                // hand-tuned size. `.caption2.monospaced()` sits at
                // the smallest text-style step and inherits Dynamic
                // Type, which a literal 10pt could not.
                .font(.caption2.weight(.medium).monospaced())
                .foregroundStyle(skin.resolvedTextSecondary)
                .frame(minWidth: 14)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: DS.Size.microCornerRadius, style: .continuous)
                        .fill(skin.resolvedTextTertiary.opacity(DS.Opacity.lightFill))
                )
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }
}
