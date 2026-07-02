import SwiftData
@testable import LeadWhisper

@MainActor
func makeTestModelContainer() throws -> ModelContainer {
    let schema = Schema([
        Contact.self,
        Opportunity.self,
        Interaction.self,
        FollowUpTask.self,
        ActivityEvent.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
