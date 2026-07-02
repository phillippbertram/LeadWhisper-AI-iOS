import SwiftData
import Testing
@testable import LeadWhisper

@MainActor
struct CRMRepositoryTests {
    @Test func repositoryDeletesContactAndUnlinksHistory() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let contact = Contact(fullName: "Sarah Klein", company: "BluePeak")
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contact: contact)
        let task = FollowUpTask(contact: contact, opportunity: opportunity, title: "Send proposal")
        let interaction = Interaction(contact: contact, opportunity: opportunity, summary: "Discovery call")
        context.insert(contact)
        context.insert(opportunity)
        context.insert(task)
        context.insert(interaction)
        try context.save()

        let repository = CRMRepository(context: context)
        try repository.deleteContact(contact)

        #expect(try repository.contacts().isEmpty)
        #expect(try repository.followUps().isEmpty)
        #expect(opportunity.contact == nil)
        #expect(interaction.contact == nil)
        #expect(try context.fetch(FetchDescriptor<ActivityEvent>()).contains { $0.title == "Contact deleted" && $0.entityKind == .contact })
    }

    @Test func repositoryDeletesOpportunityAndUnlinksInteractions() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let contact = Contact(fullName: "Sarah Klein", company: "BluePeak")
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contact: contact)
        let task = FollowUpTask(contact: contact, opportunity: opportunity, title: "Send proposal")
        let interaction = Interaction(contact: contact, opportunity: opportunity, summary: "Discovery call")
        context.insert(contact)
        context.insert(opportunity)
        context.insert(task)
        context.insert(interaction)
        try context.save()

        let repository = CRMRepository(context: context)
        try repository.deleteOpportunity(opportunity)

        #expect(try repository.opportunities().isEmpty)
        #expect(try repository.followUps().isEmpty)
        #expect(interaction.opportunity == nil)
        #expect(try repository.contacts().count == 1)
        #expect(try context.fetch(FetchDescriptor<ActivityEvent>()).contains { $0.title == "Opportunity deleted" && $0.entityKind == .opportunity })
    }

    @Test func repositoryCanCompleteArchiveAndDeleteFollowUps() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let doneTask = FollowUpTask(title: "Done task")
        let archivedTask = FollowUpTask(title: "Archive task")
        let deletedTask = FollowUpTask(title: "Delete task")
        context.insert(doneTask)
        context.insert(archivedTask)
        context.insert(deletedTask)
        try context.save()

        let repository = CRMRepository(context: context)
        try repository.markFollowUpDone(doneTask)
        try repository.archiveFollowUp(archivedTask)
        try repository.deleteFollowUp(deletedTask)

        #expect(doneTask.state == .done)
        #expect(archivedTask.state == .archived)
        #expect(try repository.followUps().contains { $0.id == doneTask.id })
        #expect(try repository.followUps().contains { $0.id == archivedTask.id })
        #expect(!(try repository.followUps().contains { $0.id == deletedTask.id }))
    }

    @Test func repositoryDeletesAllData() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let contact = Contact(fullName: "Sarah Klein", company: "BluePeak")
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contact: contact)
        let task = FollowUpTask(contact: contact, opportunity: opportunity, title: "Send proposal")
        let interaction = Interaction(contact: contact, opportunity: opportunity, summary: "Discovery call")
        let activity = ActivityEvent(title: "Manual activity", detail: "Seeded for test")
        context.insert(contact)
        context.insert(opportunity)
        context.insert(task)
        context.insert(interaction)
        context.insert(activity)
        try context.save()

        let repository = CRMRepository(context: context)
        try repository.deleteAllData()

        #expect(try repository.contacts().isEmpty)
        #expect(try repository.opportunities().isEmpty)
        #expect(try repository.followUps().isEmpty)
        #expect(try context.fetch(FetchDescriptor<Interaction>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ActivityEvent>()).isEmpty)
    }

    @Test func activityEntityKindUsesTypedRawStorage() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let event = ActivityEvent(title: "Follow-up archived", entityKind: .followUp)
        context.insert(event)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ActivityEvent>()).first
        #expect(fetched?.entityKind == .followUp)
        #expect(fetched?.entityKindRaw == ActivityEntityKind.followUp.rawValue)
    }
}
