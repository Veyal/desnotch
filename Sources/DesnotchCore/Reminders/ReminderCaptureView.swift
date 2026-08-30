import SwiftUI

/// Small, transient quick-capture surface. The title remains in SwiftUI state only
/// until it is handed to EventKit; desnotch never logs or persists it itself.
struct ReminderCaptureView: View {
    enum DueChoice: String, CaseIterable, Identifiable {
        case none
        case today
        case tomorrow

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "No date"
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            }
        }
    }

    @State private var title = ""
    @State private var dueChoice: DueChoice = .today
    @State private var saveError: String?
    @FocusState private var titleFocused: Bool

    let onCancel: () -> Void
    let onSave: (_ title: String, _ dueDate: Date?, _ isAllDay: Bool) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Reminder")
                    .font(.title3.weight(.semibold))
                Text("Saved directly to your default Reminders list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("What do you need to remember?", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(save)
                .accessibilityLabel(Text("Reminder title"))
                .accessibilityHint(Text("Saved to your default Reminders list"))
                .onChange(of: title) { _ in saveError = nil }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text(saveError))
            }

            Picker("Due", selection: $dueChoice) {
                ForEach(DueChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Reminder", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { titleFocused = true }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let calendar = Calendar.current
        switch dueChoice {
        case .none:
            handleSave(trimmed, dueDate: nil, isAllDay: false)
        case .today:
            handleSave(trimmed, dueDate: calendar.startOfDay(for: Date()), isAllDay: true)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            handleSave(trimmed, dueDate: calendar.startOfDay(for: tomorrow), isAllDay: true)
        }
    }

    private func handleSave(_ title: String, dueDate: Date?, isAllDay: Bool) {
        guard onSave(title, dueDate, isAllDay) else {
            saveError = "Couldn’t save this reminder. Check Reminders access and try again."
            titleFocused = true
            return
        }
        saveError = nil
    }
}
