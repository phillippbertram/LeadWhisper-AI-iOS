import Foundation

struct ContactEditDraft {
    var fullName: String
    var company: String
    var role: String
    var email: String
    var phone: String
    var notes: String
    var tagsText: String

    var isValid: Bool {
        fullName.nilIfBlank != nil
    }

    init(contact: Contact) {
        fullName = contact.fullName
        company = contact.company
        role = contact.role
        email = contact.email
        phone = contact.phone
        notes = contact.notes
        tagsText = contact.tags.joined(separator: ", ")
    }
}

struct OpportunityEditDraft {
    var title: String
    var company: String
    var stage: OpportunityStage
    var estimatedValueText: String
    var budgetText: String
    var expectedStart: String
    var notes: String
    var tagsText: String

    var isValid: Bool {
        let hasTitle = title.nilIfBlank != nil
        let hasEmptyOrValidEstimate = estimatedValueText.nilIfBlank == nil || parsedEstimatedValue != nil
        return hasTitle && hasEmptyOrValidEstimate
    }

    var parsedEstimatedValue: Int? {
        guard let value = estimatedValueText.nilIfBlank else { return nil }
        let digits = value.filter(\.isNumber)
        return Int(digits)
    }

    init(opportunity: Opportunity) {
        title = opportunity.title
        company = opportunity.company
        stage = opportunity.stage
        estimatedValueText = opportunity.estimatedValueEUR.map(String.init) ?? ""
        budgetText = opportunity.budgetText
        expectedStart = opportunity.expectedStart
        notes = opportunity.notes
        tagsText = opportunity.tags.joined(separator: ", ")
    }
}

struct FollowUpEditDraft {
    var title: String
    var dueDate: Date
    var usesDueDate: Bool
    var dueDateText: String
    var notes: String
    var state: FollowUpState

    var isValid: Bool {
        title.nilIfBlank != nil
    }

    init(task: FollowUpTask) {
        title = task.title
        dueDate = task.dueDate ?? .now
        usesDueDate = task.dueDate != nil
        dueDateText = task.dueDateText
        notes = task.notes
        state = task.state
    }
}
