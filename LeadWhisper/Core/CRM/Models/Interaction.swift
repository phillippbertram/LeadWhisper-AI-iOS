import Foundation
import SwiftData

@Model
final class Interaction {
    @Attribute(.unique) var id: UUID
    var contactID: UUID?
    var opportunityID: UUID?
    var summary: String
    var transcript: String
    var tags: [String]
    var occurredAt: Date

    init(
        id: UUID = UUID(),
        contactID: UUID? = nil,
        opportunityID: UUID? = nil,
        summary: String,
        transcript: String = "",
        tags: [String] = [],
        occurredAt: Date = .now
    ) {
        self.id = id
        self.contactID = contactID
        self.opportunityID = opportunityID
        self.summary = summary
        self.transcript = transcript
        self.tags = tags
        self.occurredAt = occurredAt
    }
}
