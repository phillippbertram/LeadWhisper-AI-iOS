import Foundation
import SwiftAgentKit

nonisolated enum AgentToolScope: String, CaseIterable, Codable, Sendable {
    case none
    case contacts
    case opportunities
    case followUps
    case pipeline
    case full

    var toolCount: Int {
        toolNames.count
    }

    var instructionHint: String {
        switch self {
        case .none:
            "No lookup tools are attached; draft from user facts or clarify."
        case .contacts:
            "Use contact lookup only to identify/read an existing contact."
        case .opportunities:
            "Use opportunity lookup only to identify an existing opportunity."
        case .followUps:
            "Use follow-up lookup only to identify an existing task."
        case .pipeline:
            "Use pipeline summary for counts, workload, and due-date overview."
        case .full:
            "Use lookup tools only for exact existing records, pipeline facts, or disambiguation."
        }
    }

    var toolNames: [String] {
        switch self {
        case .none:
            []
        case .contacts:
            ["findContacts", "getContactDetails"]
        case .opportunities:
            ["findOpportunities"]
        case .followUps:
            ["findFollowUps"]
        case .pipeline:
            ["getPipelineSummary"]
        case .full:
            ["findContacts", "findOpportunities", "findFollowUps", "getContactDetails", "getPipelineSummary"]
        }
    }
}

nonisolated struct AgentToolPlan: Codable, Sendable {
    var toolScope: AgentToolScope

    var reason: String
}

extension AgentToolPlan {
    nonisolated static var fallback: AgentToolPlan {
        AgentToolPlan(toolScope: .full, reason: "Tool planning failed; all read-only lookup tools are available.")
    }

    nonisolated static var outputSchema: AgentOutputSchema<AgentToolPlan> {
        AgentOutputSchema(
            name: "agent_tool_plan",
            schema: .object(
                AgentSchema.Object(
                    name: "AgentToolPlan",
                    properties: [
                        .init(
                            "toolScope",
                            description: "Smallest safe lookup tool scope for the next agent turn. Use full if uncertain.",
                            schema: .string(allowedValues: AgentToolScope.allCases.map(\.rawValue))
                        ),
                        .init("reason", description: "Short reason for the chosen tool scope.", schema: .string())
                    ]
                )
            )
        )
    }
}
