import SwiftData
import SwiftUI

struct ContactsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var contacts: [Contact]
    @Query private var opportunities: [Opportunity]
    @Query private var followUps: [FollowUpTask]
    @State private var searchText = ""
    @State private var sheet: ContactsSheet?
    @State private var pendingDeleteContact: Contact?
    @State private var pendingDeleteFollowUp: FollowUpTask?
    @State private var actionError: PresentableError?

    private var filteredContacts: [Contact] {
        let sorted = contacts.sorted {
            $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }

        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sorted
        }

        return sorted.filter {
            $0.fullName.containsSearch(searchText) ||
            $0.company.containsSearch(searchText) ||
            $0.tags.contains { $0.containsSearch(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredContacts) { contact in
                    NavigationLink {
                        ContactDetailView(
                            contact: contact,
                            opportunities: opportunities,
                            followUps: followUps,
                            editContact: { sheet = .editContact(contact.id) },
                            editFollowUp: { sheet = .editFollowUp($0.id) },
                            markFollowUpDone: { task in perform { try $0.markFollowUpDone(task) } },
                            archiveFollowUp: { task in perform { try $0.archiveFollowUp(task) } },
                            deleteFollowUp: { pendingDeleteFollowUp = $0 }
                        )
                    } label: {
                        ContactRow(contact: contact, opportunities: opportunities, followUps: followUps)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            pendingDeleteContact = contact
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)

                        Button {
                            sheet = .editContact(contact.id)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
            .navigationTitle("Contacts")
            .searchable(text: $searchText, prompt: "Search contacts")
            .talkFloatingAction {
                sheet = .agent
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .agent:
                    AgentComposerSheetView()
                case .editContact(let id):
                    if let contact = contacts.first(where: { $0.id == id }) {
                        ContactEditView(contact: contact)
                    }
                case .editFollowUp(let id):
                    if let task = followUps.first(where: { $0.id == id }) {
                        FollowUpEditView(task: task)
                    }
                }
            }
            .alert(
                "Delete contact?",
                isPresented: Binding(
                    get: { pendingDeleteContact != nil },
                    set: { if !$0 { pendingDeleteContact = nil } }
                )
            ) {
                Button("Delete Contact", role: .destructive) {
                    if let pendingDeleteContact {
                        perform { try $0.deleteContact(pendingDeleteContact) }
                    }
                    pendingDeleteContact = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteContact = nil
                }
            } message: {
                Text("Linked follow-ups are deleted. Opportunities and interactions keep their history but are unlinked.")
            }
            .alert(
                "Delete follow-up?",
                isPresented: Binding(
                    get: { pendingDeleteFollowUp != nil },
                    set: { if !$0 { pendingDeleteFollowUp = nil } }
                )
            ) {
                Button("Delete Follow-up", role: .destructive) {
                    if let pendingDeleteFollowUp {
                        perform { try $0.deleteFollowUp(pendingDeleteFollowUp) }
                    }
                    pendingDeleteFollowUp = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteFollowUp = nil
                }
            }
            .crmErrorAlert($actionError)
        }
    }

    private func perform(_ action: (CRMRepository) throws -> Void) {
        do {
            try action(CRMRepository(context: modelContext))
        } catch {
            actionError = PresentableError(error)
        }
    }
}

private enum ContactsSheet: Identifiable {
    case agent
    case editContact(UUID)
    case editFollowUp(UUID)

    var id: String {
        switch self {
        case .agent:
            "agent"
        case .editContact(let id):
            "editContact-\(id.uuidString)"
        case .editFollowUp(let id):
            "editFollowUp-\(id.uuidString)"
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    let opportunities: [Opportunity]
    let followUps: [FollowUpTask]

    private var contactOpportunities: [Opportunity] {
        opportunities.filter { $0.contactID == contact.id }
    }

    private var openFollowUps: [FollowUpTask] {
        followUps.filter { $0.contactID == contact.id && $0.state == .open }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.fullName)
                        .font(.headline)
                    if !contact.company.isEmpty {
                        Text(contact.company)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !openFollowUps.isEmpty {
                    Label("\(openFollowUps.count)", systemImage: "bell")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !contactOpportunities.isEmpty {
                HStack(spacing: 6) {
                    ForEach(contactOpportunities.prefix(2)) { opportunity in
                        StageBadge(stage: opportunity.stage)
                    }
                }
            }

            TagStrip(tags: contact.tags)
        }
        .padding(.vertical, 5)
    }
}

private struct ContactDetailView: View {
    let contact: Contact
    let opportunities: [Opportunity]
    let followUps: [FollowUpTask]
    let editContact: () -> Void
    let editFollowUp: (FollowUpTask) -> Void
    let markFollowUpDone: (FollowUpTask) -> Void
    let archiveFollowUp: (FollowUpTask) -> Void
    let deleteFollowUp: (FollowUpTask) -> Void

    private var contactOpportunities: [Opportunity] {
        opportunities.filter { $0.contactID == contact.id }
    }

    private var contactFollowUps: [FollowUpTask] {
        followUps.filter { $0.contactID == contact.id }
    }

    var body: some View {
        List {
            Section("Profile") {
                LabeledContent("Company", value: contact.company.isEmpty ? "Independent" : contact.company)
                if !contact.notes.isEmpty {
                    Text(contact.notes)
                        .font(.body)
                }
                TagStrip(tags: contact.tags)
            }

            Section("Opportunities") {
                if contactOpportunities.isEmpty {
                    ContentUnavailableView("No opportunities", systemImage: "chart.line.uptrend.xyaxis")
                } else {
                    ForEach(contactOpportunities) { opportunity in
                        OpportunitySummaryRow(opportunity: opportunity)
                    }
                }
            }

            Section("Follow-ups") {
                if contactFollowUps.isEmpty {
                    ContentUnavailableView("No follow-ups", systemImage: "bell")
                } else {
                    ForEach(contactFollowUps) { task in
                        LabeledContent(task.title, value: task.dueDateText.isEmpty ? task.state.title : task.dueDateText)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    markFollowUpDone(task)
                                } label: {
                                    Label("Done", systemImage: "checkmark")
                                }
                                .tint(.green)

                                Button {
                                    archiveFollowUp(task)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    deleteFollowUp(task)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)

                                Button {
                                    editFollowUp(task)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }
        }
        .navigationTitle(contact.fullName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editContact()
                } label: {
                    Label("Edit Contact", systemImage: "pencil")
                }
            }
        }
    }
}
