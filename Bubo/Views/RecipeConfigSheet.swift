import SwiftUI

// MARK: - Recipe Config Sheet

/// Generic configuration sheet that auto-renders UI controls
/// based on the recipe's `params` array.
/// One View for all recipes — zero per-recipe UI code.
struct RecipeConfigSheet: View {
    @Environment(\.activeSkin) private var skin
    let recipe: ScheduleRecipe
    let onExecute: (ScheduleRecipe, [String: Any]) -> Void
    let onCancel: () -> Void

    @State private var paramValues: [String: Any] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            // Header
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: recipe.icon)
                    .font(.title3)
                    .foregroundStyle(skin.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                        .font(.headline)
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text(recipe.description)
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.lg)

            // Parameters
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ForEach(recipe.params) { param in
                    paramView(for: param)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)

            Spacer(minLength: 0)

            // Actions
            SkinSeparator()
            HStack {
                Button(action: onCancel) {
                    Text("Cancel")
                }
                .buttonStyle(.action(role: .secondary))
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: {
                    Haptics.tap()
                    onExecute(recipe, paramValues)
                }) {
                    Label("Optimize", systemImage: "wand.and.stars")
                }
                .buttonStyle(.action(role: .primary))
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
        }
        .onAppear { initializeDefaults() }
    }

    // MARK: - Parameter Views

    @ViewBuilder
    private func paramView(for param: RecipeParam) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(param.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)

            switch param.kind {
            case .segmented(let options):
                segmentedParam(id: param.id, options: options)

            case .stepper(let min, let max):
                stepperParam(id: param.id, range: min...max)

            case .text:
                textParam(id: param.id)

            case .hourPicker(let range):
                hourPickerParam(id: param.id, range: range)

            case .eventPicker:
                eventPickerParam(id: param.id)
            }
        }
    }

    private func segmentedParam(id: String, options: [Int]) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? options.first ?? 0 },
            set: { paramValues[id] = $0 }
        )

        return SegmentedPillPicker(
            options: options,
            selection: binding,
            labelProvider: { minutes in
                if minutes < 60 { return "\(minutes)m" }
                let hours = minutes / 60
                let rem = minutes % 60
                if rem == 0 { return "\(hours)h" }
                return "\(hours)h\(rem)m"
            }
        )
    }

    private func stepperParam(id: String, range: ClosedRange<Int>) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? range.lowerBound },
            set: { paramValues[id] = $0 }
        )

        return Stepper(value: binding, in: range) {
            Text("\(binding.wrappedValue)")
                .font(.system(.body, design: .monospaced, weight: .medium))
                .foregroundStyle(skin.resolvedTextPrimary)
        }
    }

    private func textParam(id: String) -> some View {
        let binding = Binding<String>(
            get: { paramValues[id] as? String ?? "" },
            set: { paramValues[id] = $0 }
        )

        return TextField("Enter value", text: binding)
            .textFieldStyle(.plain)
            .font(.body)
            .padding(DS.Spacing.sm)
            .background(skin.resolvedPlatterMaterial.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    private func hourPickerParam(id: String, range: ClosedRange<Int>) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? range.lowerBound },
            set: { paramValues[id] = $0 }
        )

        return Picker("", selection: binding) {
            ForEach(Array(range), id: \.self) { hour in
                Text("\(hour):00").tag(hour)
            }
        }
        .labelsHidden()
        .frame(width: 100)
    }

    private func eventPickerParam(id: String) -> some View {
        // Shows a simple text field for event ID selection
        // In a full implementation, this would show a list of local events to pick from
        let binding = Binding<String>(
            get: { paramValues[id] as? String ?? "" },
            set: { paramValues[id] = $0 }
        )

        return TextField("Select event", text: binding)
            .textFieldStyle(.plain)
            .font(.body)
            .padding(DS.Spacing.sm)
            .background(skin.resolvedPlatterMaterial.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    // MARK: - Default Values

    private func initializeDefaults() {
        for param in recipe.params {
            switch param.kind {
            case .segmented(let options):
                if paramValues[param.id] == nil {
                    // Find default from recipe's current value
                    paramValues[param.id] = defaultForParam(param) ?? options.first
                }
            case .stepper(let min, _):
                if paramValues[param.id] == nil {
                    paramValues[param.id] = defaultForParam(param) ?? min
                }
            case .hourPicker(let range):
                if paramValues[param.id] == nil {
                    paramValues[param.id] = defaultForParam(param) ?? range.lowerBound
                }
            case .text, .eventPicker:
                break
            }
        }
    }

    private func defaultForParam(_ param: RecipeParam) -> Int? {
        switch param.target {
        case .eventMinutes(let index):
            guard index < recipe.events.count else { return nil }
            return recipe.events[index].minutes
        case .eventCount(let index):
            guard index < recipe.events.count else { return nil }
            return recipe.events[index].count
        case .workingHoursStart:
            return recipe.workingHours?.start
        case .workingHoursEnd:
            return recipe.workingHours?.end
        case .maxMeetings:
            return recipe.maxMeetingsPerDay
        case .peakEnergy:
            return recipe.peakEnergyHour
        default:
            return nil
        }
    }
}
