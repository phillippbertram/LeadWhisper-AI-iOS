import Combine
import Foundation
import OSLog
import SwiftData

@MainActor
final class CRMRepository: ObservableObject {
    private let context: ModelContext
    private static let snapshotSearch = FuzzySearch()

    init(context: ModelContext) {
        self.context = context
    }

    func contacts() throws -> [Contact] {
        try context.fetch(FetchDescriptor<Contact>(
            sortBy: [SortDescriptor(\.fullName, comparator: .localizedStandard)]
        ))
    }

    func opportunities() throws -> [Opportunity] {
        try context.fetch(FetchDescriptor<Opportunity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
    }

    func followUps() throws -> [FollowUpTask] {
        // The nil-last due-date ordering is not expressible as a store-level
        // sort descriptor, so sorting stays in memory.
        try context.fetch(FetchDescriptor<FollowUpTask>())
            .sorted(by: FollowUpTask.dueDateOrder)
    }

    func snapshot() throws -> CRMDataSnapshot {
        let contactSnapshots = try contacts().map(Self.snapshot(for:))
        let opportunitySnapshots = try opportunities().map(Self.snapshot(for:))
        let followUpSnapshots = try followUps().map(Self.snapshot(for:))

        AppLog.data.debug("Snapshot created contacts=\(contactSnapshots.count, privacy: .public) opportunities=\(opportunitySnapshots.count, privacy: .public) followUps=\(followUpSnapshots.count, privacy: .public)")

        return CRMDataSnapshot(
            contacts: contactSnapshots,
            opportunities: opportunitySnapshots,
            followUps: followUpSnapshots
        )
    }

    func contactSnapshots(matching query: String, limit: Int) throws -> [CRMContactSnapshot] {
        try Self.snapshotSearch.results(in: contacts(), matching: query, limit: limit) { contact in
            var fields: [FuzzySearch.Field] = [
                .primary(contact.fullName),
                .primary(contact.company),
                .secondary(contact.role),
                .secondary(contact.email),
                .secondary(contact.phone),
                .secondary(contact.notes)
            ]
            fields.append(contentsOf: contact.tags.map(FuzzySearch.Field.secondary))
            return fields
        }
        .map(Self.snapshot(for:))
    }

    func opportunitySnapshots(matching query: String, limit: Int) throws -> [CRMOpportunitySnapshot] {
        try Self.snapshotSearch.results(in: opportunities(), matching: query, limit: limit) { opportunity in
            var fields: [FuzzySearch.Field] = [
                .primary(opportunity.title),
                .primary(opportunity.company),
                .secondary(opportunity.stage.rawValue),
                .secondary(opportunity.budgetText),
                .secondary(opportunity.expectedStart),
                .secondary(opportunity.notes)
            ]
            fields.append(contentsOf: opportunity.tags.map(FuzzySearch.Field.secondary))
            return fields
        }
        .map(Self.snapshot(for:))
    }

    func followUpSnapshots(matching query: String, limit: Int) throws -> [CRMFollowUpSnapshot] {
        try Self.snapshotSearch.results(in: followUps(), matching: query, limit: limit) { followUp in
            [
                .primary(followUp.title),
                .secondary(followUp.dueDateText),
                .secondary(followUp.notes),
                .secondary(followUp.state.rawValue),
                .secondary(followUp.contact?.fullName ?? ""),
                .secondary(followUp.contact?.company ?? ""),
                .secondary(followUp.opportunity?.title ?? ""),
                .secondary(followUp.opportunity?.company ?? "")
            ]
        }
        .map(Self.snapshot(for:))
    }

    func contact(id string: String?) throws -> Contact? {
        guard let string, let uuid = UUID(uuidString: string) else { return nil }
        var descriptor = FetchDescriptor<Contact>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
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
            $0.role.searchKey.contains(key) ||
            $0.email.searchKey.contains(key) ||
            $0.phone.searchKey.contains(key) ||
            $0.tags.contains { $0.searchKey.contains(key) }
        }
    }

    func opportunity(id string: String?) throws -> Opportunity? {
        guard let string, let uuid = UUID(uuidString: string) else { return nil }
        var descriptor = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
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
            let contactMatches = contactID == nil || opportunity.contact?.id == contactID
            return titleMatches && companyMatches && contactMatches
        }
    }

    func followUp(id string: String?) throws -> FollowUpTask? {
        guard let string, let uuid = UUID(uuidString: string) else { return nil }
        var descriptor = FetchDescriptor<FollowUpTask>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func openFollowUps() throws -> [FollowUpTask] {
        let openRaw = FollowUpState.open.rawValue
        return try context.fetch(FetchDescriptor<FollowUpTask>(
            predicate: #Predicate { $0.stateRaw == openRaw }
        ))
        .sorted(by: FollowUpTask.dueDateOrder)
    }

    func openFollowUp(contactID: UUID? = nil, opportunityID: UUID? = nil, query: String? = nil) throws -> FollowUpTask? {
        let key = query?.searchKey ?? ""

        return try openFollowUps().first { task in
            let contactMatches = contactID == nil || task.contact?.id == contactID
            let opportunityMatches = opportunityID == nil || task.opportunity?.id == opportunityID
            let queryMatches = key.isEmpty || task.title.searchKey.contains(key) || task.notes.searchKey.contains(key)
            return contactMatches && opportunityMatches && queryMatches
        }
    }

    func insert(_ model: some PersistentModel) {
        context.insert(model)
        AppLog.data.debug("Inserted model type=\(String(describing: type(of: model)), privacy: .public)")
    }

    func addActivity(title: String, detail: String = "", entityKind: ActivityEntityKind = .system, entityID: UUID? = nil) {
        context.insert(ActivityEvent(title: title, detail: detail, entityKind: entityKind, entityID: entityID))
        AppLog.data.debug("Activity added title=\(title, privacy: .public) kind=\(entityKind.rawValue, privacy: .public) entityID=\(entityID?.uuidString ?? "-", privacy: .public)")
    }

    func deleteContact(_ contact: Contact) throws {
        stageDeleteContact(contact)
        try save()
    }

    func stageDeleteContact(_ contact: Contact) {
        let contactID = contact.id
        let contactName = contact.fullName

        AppLog.data.info("Deleting contact id=\(contactID.uuidString, privacy: .public) name=\(contactName, privacy: .private) followUpsToDelete=\(contact.followUps.count, privacy: .public) opportunitiesToUnlink=\(contact.opportunities.count, privacy: .public) interactionsToUnlink=\(contact.interactions.count, privacy: .public)")

        // Cascade removes the follow-ups; nullify unlinks opportunities and
        // interactions. Only the unlink timestamp needs manual bookkeeping.
        for opportunity in contact.opportunities {
            opportunity.updatedAt = .now
        }

        addActivity(title: "Contact deleted", detail: contactName, entityKind: .contact, entityID: contactID)
        context.delete(contact)
    }

    func deleteOpportunity(_ opportunity: Opportunity) throws {
        stageDeleteOpportunity(opportunity)
        try save()
    }

    func stageDeleteOpportunity(_ opportunity: Opportunity) {
        let opportunityID = opportunity.id
        let opportunityTitle = opportunity.title

        AppLog.data.info("Deleting opportunity id=\(opportunityID.uuidString, privacy: .public) title=\(opportunityTitle, privacy: .private) followUpsToDelete=\(opportunity.followUps.count, privacy: .public) interactionsToUnlink=\(opportunity.interactions.count, privacy: .public)")

        addActivity(title: "Opportunity deleted", detail: opportunityTitle, entityKind: .opportunity, entityID: opportunityID)
        context.delete(opportunity)
    }

    func deleteFollowUp(_ task: FollowUpTask) throws {
        stageDeleteFollowUp(task)
        try save()
    }

    func stageDeleteFollowUp(_ task: FollowUpTask) {
        AppLog.data.info("Deleting follow-up id=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .private)")
        addActivity(title: "Follow-up deleted", detail: task.title, entityKind: .followUp, entityID: task.id)
        context.delete(task)
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
        addActivity(title: "Follow-up completed", detail: task.title, entityKind: .followUp, entityID: task.id)
        try save()
    }

    func archiveFollowUp(_ task: FollowUpTask) throws {
        AppLog.data.info("Archiving follow-up id=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .private)")
        task.state = .archived
        task.updatedAt = .now
        addActivity(title: "Follow-up archived", detail: task.title, entityKind: .followUp, entityID: task.id)
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

    private static func snapshot(for contact: Contact) -> CRMContactSnapshot {
        CRMContactSnapshot(
            id: contact.id.uuidString,
            fullName: contact.fullName,
            company: contact.company,
            role: contact.role,
            email: contact.email,
            phone: contact.phone,
            notes: contact.notes,
            tags: contact.tags
        )
    }

    private static func snapshot(for opportunity: Opportunity) -> CRMOpportunitySnapshot {
        CRMOpportunitySnapshot(
            id: opportunity.id.uuidString,
            title: opportunity.title,
            company: opportunity.company,
            contactID: opportunity.contact?.id.uuidString,
            stage: opportunity.stage.rawValue,
            estimatedValueEUR: opportunity.estimatedValueEUR,
            budgetText: opportunity.budgetText,
            expectedStart: opportunity.expectedStart,
            tags: opportunity.tags
        )
    }

    private static func snapshot(for followUp: FollowUpTask) -> CRMFollowUpSnapshot {
        CRMFollowUpSnapshot(
            id: followUp.id.uuidString,
            title: followUp.title,
            contactID: followUp.contact?.id.uuidString,
            opportunityID: followUp.opportunity?.id.uuidString,
            dueDateText: followUp.dueDateText,
            notes: followUp.notes,
            state: followUp.state.rawValue
        )
    }
}
