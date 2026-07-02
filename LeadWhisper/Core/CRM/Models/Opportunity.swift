import Foundation
import SwiftData

@Model
final class Opportunity {
    #Index<Opportunity>([\.title], [\.company], [\.updatedAt])

    @Attribute(.unique) var id: UUID
    var title: String
    var company: String
    var stageRaw: String
    var estimatedValueEUR: Int?
    var budgetText: String
    var expectedStart: String
    var notes: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    var contact: Contact?

    // Deleting an opportunity removes its follow-ups but keeps interactions
    // as unlinked history.
    @Relationship(deleteRule: .cascade, inverse: \FollowUpTask.opportunity)
    var followUps: [FollowUpTask] = []

    @Relationship(deleteRule: .nullify, inverse: \Interaction.opportunity)
    var interactions: [Interaction] = []

    var stage: OpportunityStage {
        get { OpportunityStage(rawValue: stageRaw) ?? .lead }
        set { stageRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        company: String = "",
        contact: Contact? = nil,
        stage: OpportunityStage = .lead,
        estimatedValueEUR: Int? = nil,
        budgetText: String = "",
        expectedStart: String = "",
        notes: String = "",
        tags: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.company = company
        self.stageRaw = stage.rawValue
        self.estimatedValueEUR = estimatedValueEUR
        self.budgetText = budgetText
        self.expectedStart = expectedStart
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contact = contact
    }
}
