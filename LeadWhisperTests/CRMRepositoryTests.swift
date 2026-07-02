import SwiftData
import Testing
@testable import LeadWhisper

@MainActor
struct CRMRepositoryTests {
    @Test func repositoryDeletesContactAndUnlinksHistory() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let contact = Contact(fullName: "Sarah Klein", company: "BluePeak")
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contactID: contact.id)
        let task = FollowUpTask(contactID: contact.id, opportunityID: opportunity.id, title: "Send proposal")
        let interaction = Interaction(contactID: contact.id, opportunityID: opportunity.id, summary: "Discovery call")
        context.insert(contact)
        context.insert(opportunity)
        context.insert(task)
        context.insert(interaction)
        try context.save()

        let repository = CRMRepository(context: context)
        try repository.deleteContact(contact)

        #expect(try repository.contacts().isEmpty)
        #expect(try repository.followUps().isEmpty)
        #expect(opportunity.contactID == nil)
        #expect(interaction.contactID == nil)
        #expect(try context.fetch(FetchDescriptor<ActivityEvent>()).contains { $0.title == "Contact deleted" })
    }

    @Test func repositoryDeletesOpportunityAndUnlinksInteractions() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let contact = Contact(fullName: "Sarah Klein", company: "BluePeak")
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contactID: contact.id)
        let task = FollowUpTask(contactID: contact.id, opportunityID: opportunity.id, title: "Send proposal")
        let interaction = Interaction(contactID: contact.id, opportunityID: opportunity.id, summary: "Discovery call")
        context.insert(contact)
        context.insert(opportunity)
        context.insert(task)
        context.insert(interaction)
        try context.save()

        let repository = CRMRepository(context: context)
        try repository.deleteOpportunity(opportunity)

        #expect(try repository.opportunities().isEmpty)
        #expect(try repository.followUps().isEmpty)
        #expect(interaction.opportunityID == nil)
        #expect(try repository.contacts().count == 1)
        #expect(try context.fetch(FetchDescriptor<ActivityEvent>()).contains { $0.title == "Opportunity deleted" })
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
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contactID: contact.id)
        let task = FollowUpTask(contactID: contact.id, opportunityID: opportunity.id, title: "Send proposal")
        let interaction = Interaction(contactID: contact.id, opportunityID: opportunity.id, summary: "Discovery call")
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
}
