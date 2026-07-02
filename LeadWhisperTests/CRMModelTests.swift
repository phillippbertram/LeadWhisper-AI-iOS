import Testing
@testable import LeadWhisper

@MainActor
struct CRMModelTests {
    @Test func stageMappingUnderstandsDemoPhrases() {
        #expect(OpportunityStage.from("Qualified") == .qualified)
        #expect(OpportunityStage.from("Proposal Sent") == .proposalSent)
        #expect(OpportunityStage.from("Budget too low, lost") == .lost)
    }
}
