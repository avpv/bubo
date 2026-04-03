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
    var onAddTasks: (() -> Void)? = nil
    var onSwitchRecipe: ((ScheduleRecipe) -> Void)? = nil

    @State private var paramValues: [String: Any] = [:]
    @State private var selectedEventIds: Set<String> = []

    /// Whether the recipe requires events but none are available.
    private var isBlockedByNoEvents: Bool {
        recipe.needsExistingEvents && localEventsForPicker.isEmpty
    }

    /// Whether the Optimize button should be enabled.
    private var canExecute: Bool {
        if isBlockedByNoEvents { return false }
        // If there's an eventMultiPicker param, at least one event must be selected
        if recipe.params.contains(where: { $0.kind == .eventMultiPicker }) {
            return !selectedEventIds.isEmpty
        }
        return true
    }

    /// Recipes that create new events (don't require existing tasks).
    private var suggestedAlternatives: [ScheduleRecipe] {
        RecipeCatalog.quickActions.filter { $0.isCreative }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isBlockedByNoEvents {
                blockedEmptyState
            } else {
                normalConfigFlow
            }

            // Actions
            SkinSeparator()
            footer
        }
        .onAppear { initializeDefaults() }
    }

    // MARK: - Normal Config Flow

    private var normalConfigFlow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                // Header
                recipeHeader

                // Parameters
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    ForEach(recipe.params) { param in
                        paramView(for: param)
                    }
                }

                // Preview of what will happen
                recipePreview
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.md)
        }
    }

    // MARK: - Recipe Header

    private var recipeHeader: some View {
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
    }

    // MARK: - Recipe Preview

    @ViewBuilder
    private var recipePreview: some View {
        if recipe.isCreative && !recipe.events.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Will create")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(skin.resolvedTextTertiary)

                ForEach(Array(recipe.events.enumerated()), id: \.offset) { _, spec in
                    let minutes = resolvedMinutes(for: spec)
                    HStack(spacing: DS.Spacing.sm) {
                        Circle()
                            .fill(skin.accentColor)
                            .frame(width: 6, height: 6)
                        Text(spec.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(skin.resolvedTextPrimary)
                        Spacer()
                        Text(formatDuration(minutes * spec.count))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }
            }
            .padding(DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                    .fill(skin.accentColor.opacity(0.06))
            )
        } else if !recipe.events.isEmpty {
            // Events with segments get a mini timeline
            EmptyView()
        }
    }

    private func resolvedMinutes(for spec: EventSpec) -> Int {
        // Check if a param overrides this spec's minutes
        if let idx = recipe.events.firstIndex(where: { $0.title == spec.title }),
           let param = recipe.params.first(where: {
               if case .eventMinutes(let i) = $0.target { return i == idx }
               return false
           }),
           let value = paramValues[param.id] as? Int {
            return value
        }
        return spec.minutes
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    // MARK: - Blocked Empty State

    private var blockedEmptyState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(skin.resolvedTextTertiary)

            VStack(spacing: DS.Spacing.xs) {
                Text("\(recipe.name) needs tasks")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("This recipe rearranges your existing tasks.\nAdd some first, or try one that creates new blocks.")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.lg)
            }

            VStack(spacing: DS.Spacing.sm) {
                if onAddTasks != nil {
                    Button {
                        Haptics.tap()
                        onAddTasks?()
                    } label: {
                        Label("Add tasks", systemImage: "plus")
                    }
                    .buttonStyle(.action(role: .primary, size: .compact))
                }
            }

            // Suggest creative alternatives
            if let onSwitchRecipe, !suggestedAlternatives.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("Try instead")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(skin.resolvedTextTertiary)

                    ForEach(suggestedAlternatives) { alt in
                        Button {
                            Haptics.tap()
                            onSwitchRecipe(alt)
                        } label: {
                            HStack(spacing: DS.Spacing.sm) {
                                Image(systemName: alt.icon)
                                    .font(.caption)
                                    .foregroundStyle(skin.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(alt.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(skin.resolvedTextPrimary)
                                    Text(alt.description)
                                        .font(.caption2)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(skin.resolvedTextTertiary)
                            }
                            .padding(.vertical, DS.Spacing.xs)
                            .padding(.horizontal, DS.Spacing.sm)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
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
                Label(recipe.actionLabel, systemImage: recipe.isCreative ? "calendar.badge.plus" : "wand.and.stars")
            }
            .buttonStyle(.action(role: .primary))
            .disabled(!canExecute)
            .opacity(canExecute ? 1.0 : 0.5)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(skin)
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
                // Inline empty hint (main blocked state handles the full empty view)
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Text("No upcoming tasks found")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
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

