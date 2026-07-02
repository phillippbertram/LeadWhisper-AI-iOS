import Foundation
import SwiftData

@Model
final class Opportunity {
    @Attribute(.unique) var id: UUID
    var title: String
    var company: String
    var contactID: UUID?
    var stageRaw: String
    var estimatedValueEUR: Int?
    var budgetText: String
    var expectedStart: String
    var notes: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    var stage: OpportunityStage {
        get { OpportunityStage(rawValue: stageRaw) ?? .lead }
        set { stageRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        company: String = "",
        contactID: UUID? = nil,
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
        self.contactID = contactID
        self.stageRaw = stage.rawValue
        self.estimatedValueEUR = estimatedValueEUR
        self.budgetText = budgetText
        self.expectedStart = expectedStart
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
