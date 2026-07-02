struct CRMContactSnapshot: Codable, Sendable, Identifiable {
    var id: String
    var fullName: String
    var company: String
    var role: String
    var email: String
    var phone: String
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
