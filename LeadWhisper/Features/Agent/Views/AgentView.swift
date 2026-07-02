import SwiftData
import SwiftUI

struct AgentView: View {
    @State private var path: [ChangedCRMRecord] = []

    var body: some View {
        NavigationStack(path: $path) {
            AgentComposerView { record in
                path.append(record)
            }
                .navigationTitle("Agent")
                .navigationDestination(for: ChangedCRMRecord.self) { record in
                    AgentChangedRecordDestination(record: record)
                }
        }
    }
}

private struct AgentChangedRecordDestination: View {
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
                MissingChangedRecordView(record: record)
            }

        case .opportunity:
            if let opportunity = opportunities.first {
                OpportunityEditView(opportunity: opportunity)
            } else {
                MissingChangedRecordView(record: record)
            }

        case .followUp:
            if let followUp = followUps.first {
                FollowUpEditView(task: followUp)
            } else {
                MissingChangedRecordView(record: record)
            }

        case .interaction, .system:
            MissingChangedRecordView(record: record)
        }
    }
}

private struct MissingChangedRecordView: View {
    let record: ChangedCRMRecord

    var body: some View {
        ContentUnavailableView {
            Label("Record unavailable", systemImage: record.kind.systemImage)
        } description: {
            Text("\(record.title) is no longer available in local CRM data.")
        }
        .navigationTitle(record.title)
    }
}
