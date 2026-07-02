import SwiftData
import SwiftUI

struct ContactEditDraft {
    var fullName: String
    var company: String
    var role: String
    var email: String
    var phone: String
    var notes: String
    var tagsText: String

    var isValid: Bool {
        fullName.nilIfBlank != nil
    }

    init(contact: Contact) {
        fullName = contact.fullName
        company = contact.company
        role = contact.role
        email = contact.email
        phone = contact.phone
        notes = contact.notes
        tagsText = contact.tags.joined(separator: ", ")
    }
}

struct OpportunityEditDraft {
    var title: String
    var company: String
    var stage: OpportunityStage
    var estimatedValueText: String
    var budgetText: String
    var expectedStart: String
    var notes: String
    var tagsText: String

    var isValid: Bool {
        title.nilIfBlank != nil && parsedEstimatedValue != nil || title.nilIfBlank != nil && estimatedValueText.nilIfBlank == nil
    }

    var parsedEstimatedValue: Int? {
        guard let value = estimatedValueText.nilIfBlank else { return nil }
        let digits = value.filter(\.isNumber)
        return Int(digits)
    }

    init(opportunity: Opportunity) {
        title = opportunity.title
        company = opportunity.company
        stage = opportunity.stage
        estimatedValueText = opportunity.estimatedValueEUR.map(String.init) ?? ""
        budgetText = opportunity.budgetText
        expectedStart = opportunity.expectedStart
        notes = opportunity.notes
        tagsText = opportunity.tags.joined(separator: ", ")
    }
}

struct FollowUpEditDraft {
    var title: String
    var dueDate: Date
    var usesDueDate: Bool
    var dueDateText: String
    var notes: String
    var state: FollowUpState

    var isValid: Bool {
        title.nilIfBlank != nil
    }

    init(task: FollowUpTask) {
        title = task.title
        dueDate = task.dueDate ?? .now
        usesDueDate = task.dueDate != nil
        dueDateText = task.dueDateText
        notes = task.notes
        state = task.state
    }
}

struct ContactEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let contact: Contact
    @State private var draft: ContactEditDraft

    init(contact: Contact) {
        self.contact = contact
        _draft = State(initialValue: ContactEditDraft(contact: contact))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    TextField("Full name", text: $draft.fullName)
                    TextField("Company", text: $draft.company)
                    TextField("Role", text: $draft.role)
                    TextField("Email", text: $draft.email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $draft.phone)
                        .keyboardType(.phonePad)
                }

                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 96)
                    TextField("Tags, separated by commas", text: $draft.tagsText)
                }
            }
            .navigationTitle("Edit Contact")
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
        }
    }

    private func save() {
        contact.fullName = draft.fullName.nilIfBlank ?? contact.fullName
        contact.company = draft.company
        contact.role = draft.role
        contact.email = draft.email
        contact.phone = draft.phone
        contact.notes = draft.notes
        contact.tags = draft.tagsText.tagsFromCommaSeparatedText()
        contact.updatedAt = .now

        let repository = CRMRepository(context: modelContext)
        repository.addActivity(title: "Contact updated", detail: contact.fullName, entityKind: "contact", entityID: contact.id)
        try? repository.save()
        dismiss()
    }
}

struct OpportunityEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let opportunity: Opportunity
    @State private var draft: OpportunityEditDraft

    init(opportunity: Opportunity) {
        self.opportunity = opportunity
        _draft = State(initialValue: OpportunityEditDraft(opportunity: opportunity))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Opportunity") {
                    TextField("Title", text: $draft.title)
                    TextField("Company", text: $draft.company)
                    Picker("Stage", selection: $draft.stage) {
                        ForEach(OpportunityStage.allCases) { stage in
                            Text(stage.title).tag(stage)
                        }
                    }
                }

                Section("Commercials") {
                    TextField("Estimated value EUR", text: $draft.estimatedValueText)
                        .keyboardType(.numberPad)
                    TextField("Budget note", text: $draft.budgetText)
                    TextField("Expected start", text: $draft.expectedStart)
                }

                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 96)
                    TextField("Tags, separated by commas", text: $draft.tagsText)
                }
            }
            .navigationTitle("Edit Opportunity")
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
        }
    }

    private func save() {
        opportunity.title = draft.title.nilIfBlank ?? opportunity.title
        opportunity.company = draft.company
        opportunity.stage = draft.stage
        opportunity.estimatedValueEUR = draft.parsedEstimatedValue
        opportunity.budgetText = draft.budgetText
        opportunity.expectedStart = draft.expectedStart
        opportunity.notes = draft.notes
        opportunity.tags = draft.tagsText.tagsFromCommaSeparatedText()
        opportunity.updatedAt = .now

        let repository = CRMRepository(context: modelContext)
        repository.addActivity(title: "Opportunity updated", detail: opportunity.title, entityKind: "opportunity", entityID: opportunity.id)
        try? repository.save()
        dismiss()
    }
}

struct FollowUpEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let task: FollowUpTask
    @State private var draft: FollowUpEditDraft

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
        try? repository.save()
        dismiss()
    }
}

extension String {
    nonisolated func tagsFromCommaSeparatedText() -> [String] {
        split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
