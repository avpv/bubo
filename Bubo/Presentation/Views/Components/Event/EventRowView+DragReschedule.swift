import SwiftUI

// MARK: - EventRowView: Drag-to-Reschedule
//
// Vertical drag gesture that snaps to a minute step and previews
// the new time with a badge. Extracted from EventRowView.swift.

extension EventRowView {

    // MARK: - Drag-to-Reschedule

    /// Pixel-to-minute conversion: 80pt of vertical drag ≈ 60min of
    /// time shift. Apple Calendar's continuous timeline is roughly
    /// 75pt/h, so 80pt/h sits just inside that physical reference and
    /// reads as a familiar gesture for users who switch between apps.
    var pointsPerMinute: CGFloat { 80.0 / 60.0 }

    /// Snap step. The user requested «5/15-min» — we snap to 5 by
    /// default; holding `Option` could later promote to 15-min coarse
    /// snaps but the v1 keeps the gesture single-modal.
    var snapMinutes: Int { 5 }

    /// Hard cap on a single drag's reach so an enthusiastic flick can't
    /// hurl an event into next week without confirmation. ±240 minutes
    /// (4 hours) covers any reasonable «push this back to after lunch».
    var maxDeltaMinutes: Int { 240 }

    /// Drag-to-reschedule is allowed only on local, single-occurrence,
    /// upcoming events. Recurring events need explicit «this occurrence
    /// vs series» disambiguation, which the inline drag can't provide
    /// without a confirmation dialog (and a dialog defeats directness).
    /// Apple Calendar events are skipped because their occurrence-vs-
    /// series semantics under `shiftEventTime` differ from the local
    /// path's «root shift moves all occurrences» behaviour.
    var canDrag: Bool {
        actions.reschedule != nil
            && event.isLocalEvent
            && !event.isRecurring
            && event.isUpcoming
            && !isEditingTitle
    }

    var rescheduleGesture: some Gesture {
        // Long-press first, then drag — same as Apple Calendar's reorder
        // gesture. The 0.35s hold filters out accidental presses while a
        // subsequent vertical drag stays cheap (no waiting for a second
        // hold). On the long-press completion we fire `Haptics.impact()`
        // so the user feels the row «pick up» before they start moving.
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !dragArmed {
                        dragArmed = true
                        Haptics.impact()
                    }
                case .second(true, let drag?):
                    dragArmed = true
                    let h = drag.translation.height
                    let raw = Int((h / pointsPerMinute).rounded())
                    let clamped = max(-maxDeltaMinutes, min(maxDeltaMinutes, raw))
                    let snapped = (clamped / snapMinutes) * snapMinutes
                    if snapped != lastSnappedDelta {
                        Haptics.alignment()
                        lastSnappedDelta = snapped
                    }
                    dragOffsetY = h
                    dragMinuteDelta = snapped
                default:
                    break
                }
            }
            .onEnded { value in
                // Bind the second-phase drag value just to confirm the
                // gesture fully reached drag (a press that didn't progress
                // to a drag should not commit).
                if case .second(true, _?) = value, dragMinuteDelta != 0 {
                    actions.reschedule?(event, dragMinuteDelta)
                    Haptics.impact()
                }
                resetDragState()
            }
    }

    /// Spring the drag visuals back to rest.
    func resetDragState() {
        withAnimation(skin.resolvedMicroAnimation) {
            dragArmed = false
            dragOffsetY = 0
        }
        dragMinuteDelta = 0
        lastSnappedDelta = 0
    }

    /// Floating capsule showing the proposed new time + signed delta
    /// while the row is being dragged. Mirrors Apple Calendar's
    /// «hover hint» and gives the user a value to react to before
    /// they release.
    @ViewBuilder
    var rescheduleBadge: some View {
        if dragArmed {
            let delta = dragMinuteDelta
            let proposed = event.startDate.addingTimeInterval(TimeInterval(delta * 60))
            let signed = delta == 0 ? "—" : (delta > 0 ? "+\(delta)\u{00A0}min" : "\(delta)\u{00A0}min")
            // J6: surface a quiet «⌥ ripples next» hint while dragging
            // so the user discovers the modifier-key escalation. Only
            // shown when the user has actually moved the row (delta
            // ≠ 0); otherwise the badge stays minimal.
            HStack(spacing: DS.Spacing.xs) {
                Text(signed).font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.accentColor)
                Text(DS.timeFormatter.string(from: proposed))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextSecondary)
                if delta != 0 {
                    Text("\u{00B7} \u{2325} ripples")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(skin.resolvedPlatterMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(skin.accentColor.opacity(DS.Opacity.softAccent), lineWidth: DS.Border.thin))
            .elevation(.z2, skin: skin)
            .padding(.leading, DS.Spacing.lg)
            .offset(y: -DS.Spacing.lg)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
            .allowsHitTesting(false)
        }
    }

}
