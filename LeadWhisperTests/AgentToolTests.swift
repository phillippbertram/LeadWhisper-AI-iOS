import Foundation
import Testing
@testable import LeadWhisper

@MainActor
struct AgentToolTests {
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
}
