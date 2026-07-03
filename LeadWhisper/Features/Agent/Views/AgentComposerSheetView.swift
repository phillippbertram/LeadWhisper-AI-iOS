import SwiftData
import SwiftUI

struct AgentComposerSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var openedRecord: ChangedCRMRecord?
    var initialPrompt: String?

    var body: some View {
        NavigationStack {
            AgentComposerView(initialPrompt: initialPrompt) { record in
                openedRecord = record
            }
                .navigationTitle("Agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.black)
        .sheet(item: $openedRecord) { record in
            OpenedAgentRecordSheet(record: record)
        }
    }
}

private struct OpenedAgentRecordSheet: View {
    let record: ChangedCRMRecord
    @Query private var contacts: [Contact]
    @Query private var opportunities: [Opportunity]
    @Query private var followUps: [FollowUpTask]

    init(record: ChangedCRMRecord) {
        self.record = record
        let id = record.id

        var contactDescriptor = FetchDescriptor<Contact>(
            predicate: #Predicate { $0.id == id }
        )
        contactDescriptor.fetchLimit = 1
        _contacts = Query(contactDescriptor)

        var opportunityDescriptor = FetchDescriptor<Opportunity>(
            predicate: #Predicate { $0.id == id }
        )
        opportunityDescriptor.fetchLimit = 1
        _opportunities = Query(opportunityDescriptor)

        var followUpDescriptor = FetchDescriptor<FollowUpTask>(
            predicate: #Predicate { $0.id == id }
        )
        followUpDescriptor.fetchLimit = 1
        _followUps = Query(followUpDescriptor)
    }

    var body: some View {
        switch record.kind {
        case .contact:
            if let contact = contacts.first {
                ContactEditView(contact: contact)
            } else {
                MissingAgentRecordSheet(record: record)
            }

        case .opportunity:
            if let opportunity = opportunities.first {
                OpportunityEditView(opportunity: opportunity)
            } else {
                MissingAgentRecordSheet(record: record)
            }

        case .followUp:
            if let followUp = followUps.first {
                FollowUpEditView(task: followUp)
            } else {
                MissingAgentRecordSheet(record: record)
            }

        case .interaction, .system:
            MissingAgentRecordSheet(record: record)
        }
    }
}

private struct MissingAgentRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ChangedCRMRecord

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Record unavailable", systemImage: record.kind.systemImage)
            } description: {
                Text("\(record.title) is no longer available in local CRM data.")
            }
            .navigationTitle(record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
