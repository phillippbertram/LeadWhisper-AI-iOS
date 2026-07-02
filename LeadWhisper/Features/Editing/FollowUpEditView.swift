import SwiftData
import SwiftUI

struct FollowUpEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let task: FollowUpTask
    @State private var draft: FollowUpEditDraft
    @State private var saveError: PresentableError?

    init(task: FollowUpTask) {
        self.task = task
        _draft = State(initialValue: FollowUpEditDraft(task: task))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Follow-up") {
                    TextField("Title", text: $draft.title)
                    Picker("State", selection: $draft.state) {
                        ForEach(FollowUpState.allCases) { state in
                            Text(state.title).tag(state)
                        }
                    }
                    Toggle("Use date", isOn: $draft.usesDueDate)
                    if draft.usesDueDate {
                        DatePicker("Due date", selection: $draft.dueDate, displayedComponents: .date)
                    }
                    TextField("Due date text", text: $draft.dueDateText)
                }

                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 96)
                }
            }
            .navigationTitle("Edit Follow-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!draft.isValid)
                }
            }
            .crmErrorAlert($saveError)
        }
    }

    private func save() {
        task.title = draft.title.nilIfBlank ?? task.title
        task.state = draft.state
        task.dueDate = draft.usesDueDate ? draft.dueDate : nil
        task.dueDateText = draft.dueDateText.nilIfBlank ?? (draft.usesDueDate ? draft.dueDate.formatted(date: .abbreviated, time: .omitted) : "")
        task.notes = draft.notes
        task.updatedAt = .now

        let repository = CRMRepository(context: modelContext)
        repository.addActivity(title: "Follow-up updated", detail: task.title, entityKind: "followUp", entityID: task.id)
        do {
            try repository.save()
            dismiss()
        } catch {
            saveError = PresentableError(error)
        }
    }
}
