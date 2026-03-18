import SwiftUI

struct AddEventView: View {
    var reminderService: ReminderService
    var editingEvent: CalendarEvent? = nil
    var onDismiss: () -> Void
    var onSave: (_ isEdit: Bool) -> Void

    @State private var title = ""
    @State private var date = Date()
    @State private var duration: Double = 60
    @State private var location = ""
    @State private var description = ""
    @State private var showValidation = false
    @State private var useCustomReminders = false
    @State private var reminderMinutes: [Int] = [5]
    @State private var newReminderValue = 10
    @State private var recurrenceRule: RecurrenceRule? = nil

    @FocusState private var isTitleFocused: Bool
    @FocusState private var isLocationFocused: Bool
    @FocusState private var isNotesFocused: Bool

    private static let presetReminders = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    private var isEditing: Bool { editingEvent != nil }
    private var isExternal: Bool { editingEvent?.isLocalEvent == false }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var eventEndDate: Date {
        date.addingTimeInterval(duration * 60)
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { eventEndDate },
            set: { newEnd in
                let diff = newEnd.timeIntervalSince(date)
                guard diff >= 5 * 60 else { return }
                duration = diff / 60
            }
        )
    }

    /// Whether the Pomodoro mode is controlling the event duration.
    private var isPomodoroMode: Bool {
        recurrenceRule?.frequency == .minutely
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: isEditing ? "Edit Event" : "New Event",
                showBack: true,
                onBack: onDismiss
            )

            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    
                    // Title section
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        TextField("Title", text: $title, prompt: Text("Event title"))
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .focused($isTitleFocused)
                            .defaultFocus($isTitleFocused, true)

                        if showValidation && !isTitleValid {
                            Label("Title is required", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(DS.Colors.error)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(DS.Materials.platter)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                            .stroke(isTitleFocused ? DS.Colors.accent.opacity(0.8) : Color.clear, lineWidth: 2)
                    )
                    .shadow(
                        color: isTitleFocused ? DS.Colors.accent.opacity(0.15) : DS.Shadows.ambientColor,
                        radius: isTitleFocused ? DS.Shadows.ambientRadius + 1 : DS.Shadows.ambientRadius,
                        y: DS.Shadows.ambientY
                    )
                    .animation(DS.Animation.microInteraction, value: isTitleFocused)
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)
                    
                    // Date & Time
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Date & Time")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.md) {
                            GridRow {
                                Text("Starts")
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .gridColumnAlignment(.trailing)
                                
                                HStack(spacing: DS.Spacing.xs) {
                                    DatePicker("", selection: $date)
                                        .labelsHidden()
                                    TimeSlotPicker(selection: $date)
                                }
                            }
                            
                            GridRow {
                                Text("Ends")
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .gridColumnAlignment(.trailing)
                                
                                HStack(spacing: DS.Spacing.xs) {
                                    DatePicker("", selection: endDateBinding, in: date...)
                                        .labelsHidden()
                                    TimeSlotPicker(selection: endDateBinding)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                    }
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)

                    // Details
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Details")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        VStack(spacing: DS.Spacing.md) {
                            TextField("Location", text: $location, prompt: Text("Optional"))
                                .textFieldStyle(.plain)
                                .focused($isLocationFocused)

                            Divider()

                            TextField("Notes", text: $description, prompt: Text("Optional"), axis: .vertical)
                                .textFieldStyle(.plain)
                                .focused($isNotesFocused)
                                .lineLimit(3...8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                                .stroke((isLocationFocused || isNotesFocused) ? DS.Colors.accent.opacity(0.8) : Color.clear, lineWidth: 2)
                        )
                        .shadow(
                            color: (isLocationFocused || isNotesFocused) ? DS.Colors.accent.opacity(0.15) : DS.Shadows.ambientColor,
                            radius: (isLocationFocused || isNotesFocused) ? DS.Shadows.ambientRadius + 1 : DS.Shadows.ambientRadius,
                            y: DS.Shadows.ambientY
                        )
                        .animation(DS.Animation.microInteraction, value: isLocationFocused || isNotesFocused)
                    }
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)

                    // Recurrence
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        RecurrencePickerView(rule: $recurrenceRule, eventDuration: $duration, eventStartDate: date)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Spacing.md)
                            .background(DS.Materials.platter)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                            .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                    }
                    .disabled(isExternal)
                    .opacity(isExternal ? 0.6 : 1.0)

                    // Reminders
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Reminders")
                            .font(.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        VStack(alignment: .leading, spacing: DS.Spacing.md) {
                            Toggle("Custom reminders", isOn: $useCustomReminders)

                            if useCustomReminders {
                                ForEach(reminderMinutes.sorted(), id: \.self) { minutes in
                                    HStack {
                                        Label("\(DS.formatMinutes(minutes)) before", systemImage: "bell.fill")
                                        Spacer()
                                        Button(role: .destructive) {
                                            reminderMinutes.removeAll { $0 == minutes }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }

                                HStack {
                                    Stepper("\(DS.formatMinutes(newReminderValue))", value: $newReminderValue, in: 1...120)

                                    Button("Add") {
                                        if !reminderMinutes.contains(newReminderValue) {
                                            reminderMinutes.append(newReminderValue)
                                        }
                                    }
                                }

                                let available = Self.presetReminders.filter { !reminderMinutes.contains($0) }
                                if !available.isEmpty {
                                    HStack(spacing: DS.Spacing.xs) {
                                        ForEach(available.prefix(5), id: \.self) { preset in
                                            Button(DS.formatMinutes(preset)) {
                                                reminderMinutes.append(preset)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                        }
                                    }
                                }
                            } else {
                                Label("Default: 5 min before", systemImage: "bell.fill")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                        .background(DS.Materials.platter)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: DS.Popover.formMaxHeight)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .frame(minWidth: 100)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(DS.Materials.platter)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fontWeight(.medium)
                    .clipShape(Capsule())
                    .shadow(color: DS.Shadows.ambientColor, radius: 4, y: 2)
                    .buttonStyle(.plain)

                Button(isEditing ? "Save" : "Add Event") {
                    if isTitleValid {
                        saveEvent()
                    } else {
                        showValidation = true
                    }
                }
                .frame(minWidth: 100)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)
                .background(DS.Colors.accent)
                .foregroundColor(.white)
                .fontWeight(.medium)
                .buttonStyle(.plain)
                .clipShape(Capsule())
                .shadow(color: DS.Colors.accent.opacity(0.3), radius: 6, y: 3)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .background(DS.Materials.headerBar)
        }
        .frame(width: DS.Popover.width)
        .onAppear {
            if let event = editingEvent {
                title = event.title
                date = event.startDate
                duration = event.endDate.timeIntervalSince(event.startDate) / 60
                location = event.location ?? ""
                description = event.description ?? ""
                if let custom = event.customReminderMinutes, !custom.isEmpty {
                    useCustomReminders = true
                    reminderMinutes = custom
                }
                recurrenceRule = event.recurrenceRule
            }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                isTitleFocused = true
            }
        }
    }

    private func saveEvent() {
        if isExternal, let event = editingEvent {
            let minutes = useCustomReminders ? reminderMinutes.sorted() : nil
            reminderService.updateLocalReminder(for: event.id, minutes: minutes)
            onSave(true)
            return
        }

        let event = CalendarEvent(
            id: editingEvent?.id ?? UUID().uuidString,
            title: title,
            startDate: date,
            endDate: eventEndDate,
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            calendarName: "Local",
            customReminderMinutes: useCustomReminders ? reminderMinutes.sorted() : nil,
            recurrenceRule: recurrenceRule
        )
        if isEditing {
            reminderService.updateLocalEvent(event)
        } else {
            reminderService.addLocalEvent(event)
        }
        onSave(isEditing)
    }
}
