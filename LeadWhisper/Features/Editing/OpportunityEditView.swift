import SwiftData
import SwiftUI

struct OpportunityEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let opportunity: Opportunity
    @State private var draft: OpportunityEditDraft
    @State private var saveError: PresentableError?

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
            .crmErrorAlert($saveError)
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
        do {
            try repository.save()
            dismiss()
        } catch {
            saveError = PresentableError(error)
        }
    }
}
