import Foundation
import SwiftData

@Model
final class Interaction {
    @Attribute(.unique) var id: UUID
    var summary: String
    var transcript: String
    var tags: [String]
    var occurredAt: Date

    var contact: Contact?
    var opportunity: Opportunity?

    init(
        id: UUID = UUID(),
        contact: Contact? = nil,
        opportunity: Opportunity? = nil,
        summary: String,
        transcript: String = "",
        tags: [String] = [],
        occurredAt: Date = .now
    ) {
        self.id = id
        self.summary = summary
        self.transcript = transcript
        self.tags = tags
        self.occurredAt = occurredAt
        self.contact = contact
        self.opportunity = opportunity
    }
}
