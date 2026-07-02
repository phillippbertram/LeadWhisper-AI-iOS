import Foundation
import OSLog
import SwiftData

struct CRMContactSnapshot: Codable, Sendable, Identifiable {
    var id: String
    var fullName: String
    var company: String
    var notes: String
    var tags: [String]
}

struct CRMOpportunitySnapshot: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    var company: String
    var contactID: String?
    var stage: String
    var estimatedValueEUR: Int?
    var budgetText: String
    var expectedStart: String
    var tags: [String]
}

struct CRMFollowUpSnapshot: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    var contactID: String?
    var opportunityID: String?
    var dueDateText: String
    var notes: String
    var state: String
}

struct CRMDataSnapshot: Codable, Sendable {
    var contacts: [CRMContactSnapshot]
    var opportunities: [CRMOpportunitySnapshot]
    var followUps: [CRMFollowUpSnapshot]
}

@MainActor
final class CRMRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func contacts() throws -> [Contact] {
        try context.fetch(FetchDescriptor<Contact>())
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    func opportunities() throws -> [Opportunity] {
        try context.fetch(FetchDescriptor<Opportunity>())
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func followUps() throws -> [FollowUpTask] {
        try context.fetch(FetchDescriptor<FollowUpTask>())
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?):
                    left < right
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.createdAt < rhs.createdAt
                }
            }
    }

    func snapshot() throws -> CRMDataSnapshot {
        let contactSnapshots = try contacts().map {
            CRMContactSnapshot(
                id: $0.id.uuidString,
                fullName: $0.fullName,
                company: $0.company,
                notes: $0.notes,
                tags: $0.tags
            )
        }

        let opportunitySnapshots = try opportunities().map {
            CRMOpportunitySnapshot(
                id: $0.id.uuidString,
                title: $0.title,
                company: $0.company,
                contactID: $0.contactID?.uuidString,
                stage: $0.stage.rawValue,
                estimatedValueEUR: $0.estimatedValueEUR,
                budgetText: $0.budgetText,
                expectedStart: $0.expectedStart,
                tags: $0.tags
            )
        }

        let followUpSnapshots = try followUps().map {
            CRMFollowUpSnapshot(
                id: $0.id.uuidString,
                title: $0.title,
                contactID: $0.contactID?.uuidString,
                opportunityID: $0.opportunityID?.uuidString,
                dueDateText: $0.dueDateText,
                notes: $0.notes,
                state: $0.state.rawValue
            )
        }

        AppLog.data.debug("Snapshot created contacts=\(contactSnapshots.count, privacy: .public) opportunities=\(opportunitySnapshots.count, privacy: .public) followUps=\(followUpSnapshots.count, privacy: .public)")

        return CRMDataSnapshot(
            contacts: contactSnapshots,
            opportunities: opportunitySnapshots,
            followUps: followUpSnapshots
        )
    }

    func contact(id string: String?) throws -> Contact? {
        guard let string, let id = UUID(uuidString: string) else { return nil }
        return try contacts().first { $0.id == id }
    }

    func contact(named name: String?, company: String? = nil) throws -> Contact? {
        guard let name = name?.nilIfBlank else { return nil }
        let nameKey = name.searchKey
        let companyKey = company?.searchKey ?? ""

        return try contacts().first { contact in
            let contactName = contact.fullName.searchKey
            let nameMatches = contactName == nameKey || contactName.contains(nameKey) || nameKey.contains(contactName)
            let companyMatches = companyKey.isEmpty || contact.company.searchKey == companyKey || contact.company.searchKey.contains(companyKey)
            return nameMatches && companyMatches
        }
    }

    func contacts(matching query: String) throws -> [Contact] {
        let key = query.searchKey
        guard !key.isEmpty else { return try contacts() }

        return try contacts().filter {
            $0.fullName.searchKey.contains(key) ||
            $0.company.searchKey.contains(key) ||
            $0.tags.contains { $0.searchKey.contains(key) }
        }
    }

    func opportunity(id string: String?) throws -> Opportunity? {
        guard let string, let id = UUID(uuidString: string) else { return nil }
        return try opportunities().first { $0.id == id }
    }

    func opportunity(title: String?, company: String? = nil, contactID: UUID? = nil) throws -> Opportunity? {
        guard let title = title?.nilIfBlank else { return nil }
        let titleKey = title.searchKey
        let companyKey = company?.searchKey ?? ""

        return try opportunities().first { opportunity in
            let titleMatches = opportunity.title.searchKey == titleKey ||
                opportunity.title.searchKey.contains(titleKey) ||
                titleKey.contains(opportunity.title.searchKey)
            let companyMatches = companyKey.isEmpty ||
                opportunity.company.searchKey == companyKey ||
                opportunity.company.searchKey.contains(companyKey)
            let contactMatches = contactID == nil || opportunity.contactID == contactID
            return titleMatches && companyMatches && contactMatches
        }
    }

    func followUp(id string: String?) throws -> FollowUpTask? {
        guard let string, let id = UUID(uuidString: string) else { return nil }
        return try followUps().first { $0.id == id }
    }

    func openFollowUp(contactID: UUID? = nil, opportunityID: UUID? = nil, query: String? = nil) throws -> FollowUpTask? {
        let key = query?.searchKey ?? ""

        return try followUps().first { task in
            guard task.state == .open else { return false }
            let contactMatches = contactID == nil || task.contactID == contactID
            let opportunityMatches = opportunityID == nil || task.opportunityID == opportunityID
            let queryMatches = key.isEmpty || task.title.searchKey.contains(key) || task.notes.searchKey.contains(key)
            return contactMatches && opportunityMatches && queryMatches
        }
    }

    func insert(_ model: some PersistentModel) {
        context.insert(model)
        AppLog.data.debug("Inserted model type=\(String(describing: type(of: model)), privacy: .public)")
    }

    func addActivity(title: String, detail: String = "", entityKind: String = "", entityID: UUID? = nil) {
        context.insert(ActivityEvent(title: title, detail: detail, entityKind: entityKind, entityID: entityID))
        AppLog.data.debug("Activity added title=\(title, privacy: .public) kind=\(entityKind, privacy: .public) entityID=\(entityID?.uuidString ?? "-", privacy: .public)")
    }

    func deleteContact(_ contact: Contact) throws {
        let contactID = contact.id
        let contactName = contact.fullName

        let tasksToDelete = try followUps().filter { $0.contactID == contactID }
        let opportunitiesToUnlink = try opportunities().filter { $0.contactID == contactID }
        let descriptor = FetchDescriptor<Interaction>()
        let interactionsToUnlink = try context.fetch(descriptor).filter { $0.contactID == contactID }

        AppLog.data.info("Deleting contact id=\(contactID.uuidString, privacy: .public) name=\(contactName, privacy: .private) followUpsToDelete=\(tasksToDelete.count, privacy: .public) opportunitiesToUnlink=\(opportunitiesToUnlink.count, privacy: .public) interactionsToUnlink=\(interactionsToUnlink.count, privacy: .public)")

        for task in tasksToDelete {
            context.delete(task)
        }

        for opportunity in opportunitiesToUnlink {
            opportunity.contactID = nil
            opportunity.updatedAt = .now
        }

        for interaction in interactionsToUnlink {
            interaction.contactID = nil
        }

        addActivity(title: "Contact deleted", detail: contactName, entityKind: "contact", entityID: contactID)
        context.delete(contact)
        try save()
    }

    func deleteOpportunity(_ opportunity: Opportunity) throws {
        let opportunityID = opportunity.id
        let opportunityTitle = opportunity.title

        let tasksToDelete = try followUps().filter { $0.opportunityID == opportunityID }
        let descriptor = FetchDescriptor<Interaction>()
        let interactionsToUnlink = try context.fetch(descriptor).filter { $0.opportunityID == opportunityID }

        AppLog.data.info("Deleting opportunity id=\(opportunityID.uuidString, privacy: .public) title=\(opportunityTitle, privacy: .private) followUpsToDelete=\(tasksToDelete.count, privacy: .public) interactionsToUnlink=\(interactionsToUnlink.count, privacy: .public)")

        for task in tasksToDelete {
            context.delete(task)
        }

        for interaction in interactionsToUnlink {
            interaction.opportunityID = nil
        }

        addActivity(title: "Opportunity deleted", detail: opportunityTitle, entityKind: "opportunity", entityID: opportunityID)
        context.delete(opportunity)
        try save()
    }

    func deleteFollowUp(_ task: FollowUpTask) throws {
        AppLog.data.info("Deleting follow-up id=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .private)")
        addActivity(title: "Follow-up deleted", detail: task.title, entityKind: "followUp", entityID: task.id)
        context.delete(task)
        try save()
    }

    func deleteAllData() throws {
        let activityEvents = try context.fetch(FetchDescriptor<ActivityEvent>())
        let followUps = try context.fetch(FetchDescriptor<FollowUpTask>())
        let interactions = try context.fetch(FetchDescriptor<Interaction>())
        let opportunities = try context.fetch(FetchDescriptor<Opportunity>())
        let contacts = try context.fetch(FetchDescriptor<Contact>())

        AppLog.data.info("Deleting all data contacts=\(contacts.count, privacy: .public) opportunities=\(opportunities.count, privacy: .public) followUps=\(followUps.count, privacy: .public) interactions=\(interactions.count, privacy: .public) activity=\(activityEvents.count, privacy: .public)")

        for event in activityEvents {
            context.delete(event)
        }
        for task in followUps {
            context.delete(task)
        }
        for interaction in interactions {
            context.delete(interaction)
        }
        for opportunity in opportunities {
            context.delete(opportunity)
        }
        for contact in contacts {
            context.delete(contact)
        }

        try save()
    }

    func markFollowUpDone(_ task: FollowUpTask) throws {
        AppLog.data.info("Marking follow-up done id=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .private)")
        task.state = .done
        task.updatedAt = .now
        addActivity(title: "Follow-up completed", detail: task.title, entityKind: "followUp", entityID: task.id)
        try save()
    }

    func archiveFollowUp(_ task: FollowUpTask) throws {
        AppLog.data.info("Archiving follow-up id=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .private)")
        task.state = .archived
        task.updatedAt = .now
        addActivity(title: "Follow-up archived", detail: task.title, entityKind: "followUp", entityID: task.id)
        try save()
    }

    func save() throws {
        do {
            try context.save()
            AppLog.data.debug("SwiftData context saved")
        } catch {
            AppLog.data.error("SwiftData save failed error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
