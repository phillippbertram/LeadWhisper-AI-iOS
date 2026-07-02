import Testing
@testable import LeadWhisper

@MainActor
struct EditDraftTests {
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
}
