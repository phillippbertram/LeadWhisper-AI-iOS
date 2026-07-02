import Foundation

struct AgentToolDataSource: Sendable {
    var contacts: @Sendable (_ query: String, _ limit: Int) async throws -> [CRMContactSnapshot]
    var opportunities: @Sendable (_ query: String, _ limit: Int) async throws -> [CRMOpportunitySnapshot]
    var followUps: @Sendable (_ query: String, _ limit: Int) async throws -> [CRMFollowUpSnapshot]
    var snapshot: @Sendable () async throws -> CRMDataSnapshot

    @MainActor
    static func live(repository: CRMRepository) -> AgentToolDataSource {
        AgentToolDataSource(
            contacts: { query, limit in
                try await MainActor.run {
                    try repository.contactSnapshots(matching: query, limit: limit)
                }
            },
            opportunities: { query, limit in
                try await MainActor.run {
                    try repository.opportunitySnapshots(matching: query, limit: limit)
                }
            },
            followUps: { query, limit in
                try await MainActor.run {
                    try repository.followUpSnapshots(matching: query, limit: limit)
                }
            },
            snapshot: {
                try await MainActor.run {
                    try repository.snapshot()
                }
            }
        )
    }
}
