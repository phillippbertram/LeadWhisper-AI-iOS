import FactoryKit
import SwiftData
import SwiftUI

struct ContactsView: View {
    @InjectedObject(\.crmRepository) private var crmRepository
    @Query(sort: [SortDescriptor(\Contact.fullName, comparator: .localizedStandard)])
    private var contacts: [Contact]
    @State private var searchText = ""
    @State private var sheet: ContactsSheet?
    @State private var pendingDeleteContact: Contact?
    @State private var pendingDeleteFollowUp: FollowUpTask?
    @State private var actionError: PresentableError?

    private var filteredContacts: [Contact] {
        // The diacritic-insensitive searchKey matching cannot run in a
        // #Predicate, so the search filter stays in memory.
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return contacts
        }

        return contacts.filter {
            $0.fullName.containsSearch(searchText) ||
            $0.company.containsSearch(searchText) ||
            $0.tags.contains { $0.containsSearch(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Contacts")
                .searchable(text: $searchText, prompt: "Search contacts")
                .talkFloatingAction {
                    sheet = .agent(initialPrompt: nil)
                }
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .agent(let initialPrompt):
                        AgentComposerSheetView(initialPrompt: initialPrompt)
                    case .editContact(let contact):
                        ContactEditView(contact: contact)
                    case .editFollowUp(let task):
                        FollowUpEditView(task: task)
                    }
                }
                .confirmationDialog(
                    "Delete contact?",
                    isPresented: .init(isPresenting: $pendingDeleteContact),
                    titleVisibility: .visible,
                    presenting: pendingDeleteContact
                ) { contact in
                    Button("Delete Contact", role: .destructive) {
                        perform { try $0.deleteContact(contact) }
                        pendingDeleteContact = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDeleteContact = nil
                    }
                } message: { _ in
                    Text("Linked follow-ups are deleted. Opportunities and interactions keep their history but are unlinked.")
                }
                .confirmationDialog(
                    "Delete follow-up?",
                    isPresented: .init(isPresenting: $pendingDeleteFollowUp),
                    titleVisibility: .visible,
                    presenting: pendingDeleteFollowUp
                ) { task in
                    Button("Delete Follow-up", role: .destructive) {
                        perform { try $0.deleteFollowUp(task) }
                        pendingDeleteFollowUp = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDeleteFollowUp = nil
                    }
                }
                .crmErrorAlert($actionError)
        }
    }

    @ViewBuilder
    private var content: some View {
        if contacts.isEmpty {
            ContentUnavailableView {
                Label("No contacts yet", systemImage: "person.2")
            } description: {
                Text("Capture a lead update to create your first local contact.")
            } actions: {
                Button {
                    sheet = .agent(initialPrompt: nil)
                } label: {
                    Label("Type Update", systemImage: "keyboard")
                }
            }
        } else if filteredContacts.isEmpty {
            ContentUnavailableView {
                Label("No matching contacts", systemImage: "magnifyingglass")
            } description: {
                Text("Try a different name, company, or tag.")
            } actions: {
                Button {
                    sheet = .agent(initialPrompt: nil)
                } label: {
                    Label("Type Update", systemImage: "keyboard")
                }
            }
        } else {
            contactList
        }
    }

    private var contactList: some View {
        List {
            ForEach(filteredContacts) { contact in
                NavigationLink {
                    ContactDetailView(
                        contact: contact,
                        editContact: { sheet = .editContact(contact) },
                        startAgent: { sheet = .agent(initialPrompt: agentPrompt(for: contact)) },
                        editFollowUp: { sheet = .editFollowUp($0) },
                        updateFollowUpWithAgent: { sheet = .agent(initialPrompt: agentPrompt(for: $0, contact: contact)) },
                        markFollowUpDone: { task in perform { try $0.markFollowUpDone(task) } },
                        archiveFollowUp: { task in perform { try $0.archiveFollowUp(task) } },
                        deleteFollowUp: { pendingDeleteFollowUp = $0 }
                    )
                } label: {
                    ContactRow(contact: contact)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        sheet = .agent(initialPrompt: agentPrompt(for: contact))
                    } label: {
                        Label("Agent", systemImage: "sparkles")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        pendingDeleteContact = contact
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)

                    Button {
                        sheet = .editContact(contact)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    private func perform(_ action: (CRMRepository) throws -> Void) {
        do {
            try action(crmRepository)
        } catch {
            actionError = PresentableError(error)
        }
    }

    private func agentPrompt(for contact: Contact) -> String {
        if contact.company.isEmpty {
            return "Update \(contact.fullName)"
        }
        return "Update \(contact.fullName) at \(contact.company)"
    }

    private func agentPrompt(for task: FollowUpTask, contact: Contact) -> String {
        "Update the follow-up \(task.title) for \(contact.fullName)"
    }
}

private enum ContactsSheet: Identifiable {
    case agent(initialPrompt: String?)
    case editContact(Contact)
    case editFollowUp(FollowUpTask)

    var id: String {
        switch self {
        case .agent(let initialPrompt):
            "agent-\(initialPrompt ?? "blank")"
        case .editContact(let contact):
            "editContact-\(contact.id.uuidString)"
        case .editFollowUp(let task):
            "editFollowUp-\(task.id.uuidString)"
        }
    }
}

private struct ContactRow: View {
    let contact: Contact

    private var contactOpportunities: [Opportunity] {
        contact.opportunities.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var openFollowUps: [FollowUpTask] {
        contact.followUps.filter { $0.state == .open }
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
    let editContact: () -> Void
    let startAgent: () -> Void
    let editFollowUp: (FollowUpTask) -> Void
    let updateFollowUpWithAgent: (FollowUpTask) -> Void
    let markFollowUpDone: (FollowUpTask) -> Void
    let archiveFollowUp: (FollowUpTask) -> Void
    let deleteFollowUp: (FollowUpTask) -> Void

    private var contactOpportunities: [Opportunity] {
        contact.opportunities.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var contactFollowUps: [FollowUpTask] {
        contact.followUps.sorted(by: FollowUpTask.dueDateOrder)
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
                                    updateFollowUpWithAgent(task)
                                } label: {
                                    Label("Agent", systemImage: "sparkles")
                                }
                                .tint(.blue)

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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    startAgent()
                } label: {
                    Label("Agent", systemImage: "sparkles")
                }
            }

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
