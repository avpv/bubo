import SwiftUI

// MARK: - Recipe Config Sheet

/// Generic configuration sheet that auto-renders UI controls
/// based on the recipe's `params` array.
/// One View for all recipes — zero per-recipe UI code.
struct RecipeConfigSheet: View {
    @Environment(\.activeSkin) private var skin
    let recipe: ScheduleRecipe
    var reminderService: ReminderService? = nil
    let onExecute: (ScheduleRecipe, [String: Any]) -> Void
    let onCancel: () -> Void

    @State private var paramValues: [String: Any] = [:]
    @State private var selectedEventIds: Set<String> = []

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

            case .eventMultiPicker:
                eventMultiPickerParam(id: param.id)
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

    private func eventMultiPickerParam(id: String) -> some View {
        let events = localEventsForPicker

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if events.isEmpty {
                Text("No tasks to select")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.vertical, DS.Spacing.sm)
            } else {
                // Select all / none toggle
                HStack {
                    let allSelected = selectedEventIds.count == events.count
                    Button {
                        if allSelected {
                            selectedEventIds.removeAll()
                        } else {
                            selectedEventIds = Set(events.map(\.id))
                        }
                        paramValues[id] = Array(selectedEventIds)
                    } label: {
                        Text(allSelected ? "Deselect all" : "Select all")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(skin.accentColor)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("\(selectedEventIds.count) of \(events.count)")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }

                ForEach(events, id: \.id) { event in
                    eventRow(event: event, paramId: id)
                }
            }
        }
    }

    private func eventRow(event: CalendarEvent, paramId: String) -> some View {
        let isSelected = selectedEventIds.contains(event.id)

        return Button {
            if isSelected {
                selectedEventIds.remove(event.id)
            } else {
                selectedEventIds.insert(event.id)
            }
            paramValues[paramId] = Array(selectedEventIds)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? skin.accentColor : skin.resolvedTextTertiary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)

                    Text(event.formattedTimeRange)
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }

                Spacer()

                Text("\(Int(event.duration / 60))m")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(.vertical, DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.sm)
            .background(isSelected ? skin.accentColor.opacity(0.06) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
        }
        .buttonStyle(.plain)
    }

    private var localEventsForPicker: [CalendarEvent] {
        guard let service = reminderService else { return [] }
        return service.localEvents
            .filter { $0.isUpcoming }
            .sorted { $0.startDate < $1.startDate }
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
            case .eventMultiPicker:
                // Default: select all local events
                if selectedEventIds.isEmpty {
                    let allIds = localEventsForPicker.map(\.id)
                    selectedEventIds = Set(allIds)
                    paramValues[param.id] = allIds
                }
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
