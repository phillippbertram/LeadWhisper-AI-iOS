import SwiftData
import Testing
@testable import LeadWhisper

@MainActor
struct ChangeExecutorTests {
    @Test func executorCreatesLeadOpportunityFollowUpAndInteraction() throws {
        let container = try makeTestModelContainer()
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
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        try DemoDataSeeder.seed(in: context)

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
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        try DemoDataSeeder.seed(in: context)
        let repository = CRMRepository(context: context)

        let draft = DemoAgentParser.makeDraft(
            transcript: "Update for Max: He wants a proposal next week.",
            snapshot: try repository.snapshot()
        )

        #expect(draft.clarification != nil)
        #expect(draft.proposedChanges.isEmpty)
    }

    @Test func clarificationAnswerResolvesMaxDraft() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        try DemoDataSeeder.seed(in: context)
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
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let sarah = Contact(fullName: "Sarah Klein", company: "BluePeak")
        let opportunity = Opportunity(title: "Flutter app support", company: "BluePeak", contact: sarah, stage: .proposalSent)
        let task = FollowUpTask(contact: sarah, opportunity: opportunity, title: "Send proposal to Sarah", dueDateText: "Friday")
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

    @Test func demoParserProducesTypedFactsAndActions() {
        let draft = DemoAgentParser.makeDraft(
            transcript: "New contact: Sarah Klein from BluePeak. Create an opportunity and remind me on Friday."
        )

        #expect(draft.detectedFacts.contains { $0.kind == .contact })
        #expect(draft.detectedFacts.contains { $0.kind == .company })
        #expect(draft.proposedChanges.contains { $0.action == .createContact })
        #expect(draft.proposedChanges.contains { $0.action == .createOpportunity })
    }
}
