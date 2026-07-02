import Foundation
import SwiftData

@Model
final class Contact {
    #Index<Contact>([\.fullName], [\.company])

    @Attribute(.unique) var id: UUID
    var fullName: String
    var company: String
    var role: String
    var email: String
    var phone: String
    var notes: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    // Deleting a contact removes its follow-ups but keeps opportunities and
    // interactions as unlinked history.
    @Relationship(deleteRule: .nullify, inverse: \Opportunity.contact)
    var opportunities: [Opportunity] = []

    @Relationship(deleteRule: .cascade, inverse: \FollowUpTask.contact)
    var followUps: [FollowUpTask] = []

    @Relationship(deleteRule: .nullify, inverse: \Interaction.contact)
    var interactions: [Interaction] = []

    init(
        id: UUID = UUID(),
        fullName: String,
        company: String = "",
        role: String = "",
        email: String = "",
        phone: String = "",
        notes: String = "",
        tags: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fullName = fullName
        self.company = company
        self.role = role
        self.email = email
        self.phone = phone
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
