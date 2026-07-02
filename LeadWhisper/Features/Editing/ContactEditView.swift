import SwiftData
import SwiftUI

struct ContactEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.crmRepository) private var injectedRepository
    @Environment(\.dismiss) private var dismiss
    let contact: Contact
    @State private var draft: ContactEditDraft
    @State private var saveError: PresentableError?

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
            .crmErrorAlert($saveError)
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

        let repository = injectedRepository.repository(fallback: modelContext)
        repository.addActivity(title: "Contact updated", detail: contact.fullName, entityKind: .contact, entityID: contact.id)
        do {
            try repository.save()
            dismiss()
        } catch {
            saveError = PresentableError(error)
        }
    }
}
