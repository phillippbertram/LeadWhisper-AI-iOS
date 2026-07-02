import Foundation
import FoundationModels
import Speech
import SwiftData
import Testing
@testable import LeadWhisper

@MainActor
struct LeadWhisperTests {
    @Test func stageMappingUnderstandsDemoPhrases() {
        #expect(OpportunityStage.from("Qualified") == .qualified)
        #expect(OpportunityStage.from("Proposal Sent") == .proposalSent)
        #expect(OpportunityStage.from("Budget too low, lost") == .lost)
    }

    @Test func dueDateResolverFindsNextWeekday() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2026
        components.month = 7
        components.day = 2
        let thursday = try #require(components.date)

        let friday = try #require(DueDateResolver.date(from: "Friday", now: thursday, calendar: components.calendar!))
        #expect(components.calendar!.component(.weekday, from: friday) == 6)

        let nextTuesday = try #require(DueDateResolver.date(from: "next Tuesday", now: thursday, calendar: components.calendar!))
        #expect(components.calendar!.component(.weekday, from: nextTuesday) == 3)
    }

    @Test func executorCreatesLeadOpportunityFollowUpAndInteraction() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = CRMRepository(context: context)
        let draft = DemoAgentParser.makeDraft(
            transcript: "New contact: Sarah Klein from BluePeak. She needs help with a Flutter app in August. Budget around 20,000 Euro. Set her to Qualified and remind me on Friday to send a proposal."
        )

        let result = try ChangeExecutor(repository: repository).apply(draft, transcript: "sample")

        #expect(result.changedTitles.contains("Create Contact"))
        #expect(try repository.contacts().contains { $0.fullName == "Sarah Klein" })
        #expect(try repository.opportunities().contains { $0.company == "BluePeak" && $0.stage == .qualified })
        #expect(try repository.followUps().contains { $0.title.contains("Sarah") && $0.state == .open })
    }

    @Test func executorUpdatesExistingOpportunityWithoutDuplicatingContact() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        DemoDataSeeder.seed(in: context)

        let repository = CRMRepository(context: context)
        let before = try repository.contacts().count
        let draft = DemoAgentParser.makeDraft(
            transcript: "Update for Max Mueller: He liked the proposal. Set the opportunity to Proposal Sent and create a follow-up task for Thursday.",
            snapshot: try repository.snapshot()
        )

        _ = try ChangeExecutor(repository: repository).apply(draft, transcript: "sample")

        #expect(try repository.contacts().count == before)
        #expect(try repository.opportunities().contains { $0.title == "Native iOS app" && $0.stage == .proposalSent })
    }

    @Test func ambiguousMaxProducesClarificationAndNoChanges() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        DemoDataSeeder.seed(in: context)
        let repository = CRMRepository(context: context)

        let draft = DemoAgentParser.makeDraft(
            transcript: "Update for Max: He wants a proposal next week.",
            snapshot: try repository.snapshot()
        )

        #expect(draft.clarification != nil)
        #expect(draft.proposedChanges.isEmpty)
    }

    @Test func clarificationAnswerResolvesMaxDraft() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        DemoDataSeeder.seed(in: context)
        let repository = CRMRepository(context: context)

        let draft = DemoAgentParser.makeDraft(
            transcript: "Update for Max: He wants a proposal next week.\nClarification answer: Max Schneider, Northstar Studio",
            snapshot: try repository.snapshot()
        )

        #expect(draft.clarification == nil)
        #expect(!draft.proposedChanges.isEmpty)
        #expect(draft.proposedChanges.contains { $0.contactName == "Max Schneider" })
    }

    @Test func lostOpportunityArchivesOpenFollowUps() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let sarah = Contact(fullName: "Sarah Klein", company: "BluePeak")
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contactID: sarah.id, stage: .proposalSent)
        let task = FollowUpTask(contactID: sarah.id, opportunityID: opportunity.id, title: "Send proposal to Sarah", dueDateText: "Friday")
        context.insert(sarah)
        context.insert(opportunity)
        context.insert(task)
        try context.save()

        let repository = CRMRepository(context: context)
        let draft = DemoAgentParser.makeDraft(transcript: "Mark the BluePeak opportunity as lost. Reason: budget too low. Archive open follow-ups for it.")

        _ = try ChangeExecutor(repository: repository).apply(draft, transcript: "sample")

        #expect(opportunity.stage == .lost)
        #expect(task.state == .archived)
    }

    @Test func repositoryDeletesContactAndUnlinksHistory() throws {
        let container = try makeContainer()
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
        let container = try makeContainer()
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
        let container = try makeContainer()
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
        let container = try makeContainer()
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

    @Test func editDraftValidationRequiresCoreTitles() {
        let emptyContact = Contact(fullName: "")
        let validContact = Contact(fullName: "Julia", company: "Northwind")
        #expect(ContactEditDraft(contact: emptyContact).isValid == false)
        #expect(ContactEditDraft(contact: validContact).isValid)

        let opportunity = Opportunity(title: "Project")
        var opportunityDraft = OpportunityEditDraft(opportunity: opportunity)
        #expect(opportunityDraft.isValid)
        opportunityDraft.estimatedValueText = "not a number"
        #expect(opportunityDraft.isValid == false)

        let task = FollowUpTask(title: "")
        #expect(FollowUpEditDraft(task: task).isValid == false)
    }

    @Test func lookupModeRoutesCompactToolSets() {
        #expect(LeadAgentService.lookupMode(for: "New contact: Sarah Klein from BluePeak") == .none)

        let updateMode = LeadAgentService.lookupMode(for: "Update for Max Mueller: Set the opportunity to Proposal Sent.")
        #expect(updateMode.contains(.contacts))
        #expect(updateMode.contains(.opportunities))
        #expect(!updateMode.contains(.followUps))

        let rescheduleMode = LeadAgentService.lookupMode(for: "Reschedule Sarah's follow-up to next Tuesday.")
        #expect(rescheduleMode.contains(.followUps))
        #expect(!rescheduleMode.contains(.opportunities))

        let lostMode = LeadAgentService.lookupMode(for: "Mark the BluePeak opportunity as lost and archive follow-ups.")
        #expect(lostMode.contains(.opportunities))
        #expect(lostMode.contains(.followUps))
    }

    @Test func lookupToolsRejectEmptyQueriesAndCapResults() async throws {
        let contacts = (0..<7).map {
            CRMContactSnapshot(
                id: UUID().uuidString,
                fullName: "Anna \($0)",
                company: "BrightApps",
                notes: "Flutter performance work",
                tags: ["Flutter"]
            )
        }

        let emptyContacts = try await FindContactsTool(contacts: contacts).call(arguments: FindContactsArguments(query: " "))
        #expect(emptyContacts == ToolText.emptyQuery)

        let cappedContacts = try await FindContactsTool(contacts: contacts).call(arguments: FindContactsArguments(query: "Anna"))
        #expect(cappedContacts.split(separator: "\n").count == ToolText.resultLimit)
        #expect(!cappedContacts.contains("Anna 5"))

        let opportunities = (0..<7).map {
            CRMOpportunitySnapshot(
                id: UUID().uuidString,
                title: "iOS App \($0)",
                company: "Acme Labs",
                contactID: nil,
                stage: OpportunityStage.lead.rawValue,
                estimatedValueEUR: 10_000 + $0,
                budgetText: "",
                expectedStart: "August",
                tags: ["iOS"]
            )
        }

        let emptyOpportunities = try await FindOpportunitiesTool(opportunities: opportunities).call(arguments: FindOpportunitiesArguments(query: ""))
        #expect(emptyOpportunities == ToolText.emptyQuery)
        let cappedOpportunities = try await FindOpportunitiesTool(opportunities: opportunities).call(arguments: FindOpportunitiesArguments(query: "ios"))
        #expect(cappedOpportunities.split(separator: "\n").count == ToolText.resultLimit)

        let followUps = (0..<7).map {
            CRMFollowUpSnapshot(
                id: UUID().uuidString,
                title: "Send proposal \($0)",
                contactID: nil,
                opportunityID: nil,
                dueDateText: "Friday",
                notes: "Proposal follow-up",
                state: FollowUpState.open.rawValue
            )
        }

        let emptyFollowUps = try await FindFollowUpsTool(followUps: followUps).call(arguments: FindFollowUpsArguments(query: ""))
        #expect(emptyFollowUps == ToolText.emptyQuery)
        let cappedFollowUps = try await FindFollowUpsTool(followUps: followUps).call(arguments: FindFollowUpsArguments(query: "proposal"))
        #expect(cappedFollowUps.split(separator: "\n").count == ToolText.resultLimit)
    }

    @Test func contextWindowErrorUsesFriendlyFallbackMapping() {
        let error = LanguageModelSession.GenerationError.exceededContextWindowSize(
            LanguageModelSession.GenerationError.Context(debugDescription: "too many tokens")
        )
        #expect(LeadAgentService.isContextWindowError(error))
        #expect(LeadAgentService.isContextWindowError(PlainContextError()))
    }

    @Test func voiceAuthorizationStatusesMapToFriendlyFallbackMessages() {
        #expect(VoiceInputService.statusMessage(for: .denied).contains("Type the transcript"))
        #expect(VoiceInputService.statusMessage(for: .restricted).contains("restricted"))
        #expect(VoiceInputService.statusMessage(for: .notDetermined).contains("required"))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Contact.self,
            Opportunity.self,
            Interaction.self,
            FollowUpTask.self,
            ActivityEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private struct PlainContextError: LocalizedError {
    var errorDescription: String? {
        "Exceeded Model context window size"
    }
}
